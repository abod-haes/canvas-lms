# frozen_string_literal: true

#
# Copyright (C) 2023 - present Instructure, Inc.
#
# This file is part of Canvas.
#
# Canvas is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, version 3 of the License.
#
# Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
# details.
#
# You should have received a copy of the GNU Affero General Public License along
# with this program. If not, see <http://www.gnu.org/licenses/>.
#

class GradingSchemesJsonController < ApplicationController
  extend GradingSchemeSerializer

  GRADING_SCHEMES_LIMIT = 100
  USED_LOCATIONS_PER_PAGE = 50
  before_action :require_context
  before_action :require_user
  before_action :validate_read_permission, only: %i[grouped_list detail_list summary_list show]

  def grouped_list
    standards = grading_standards_for_context.sorted.limit(GRADING_SCHEMES_LIMIT)
    render json: {
      archived: standards.select(&:archived?).map do |grading_standard|
        GradingSchemesJsonController.to_grading_scheme_json(grading_standard, @current_user)
      end,
      active: standards.select(&:active?).map do |grading_standard|
        GradingSchemesJsonController.to_grading_scheme_json(grading_standard, @current_user)
      end
    }
  end

  def detail_list
    grading_standards = grading_standards_for_context(include_parent_accounts: false)
                        .sorted.limit(GRADING_SCHEMES_LIMIT)
    respond_to do |format|
      format.json do
        render json: grading_standards.map { |grading_standard|
          GradingSchemesJsonController.to_grading_scheme_json(grading_standard, @current_user)
        }
      end
    end
  end

  def summary_list
    grading_standards = grading_standards_for_context.sorted.limit(GRADING_SCHEMES_LIMIT)
    respond_to do |format|
      format.json do
        render json: grading_standards.map { |grading_standard|
          GradingSchemesJsonController.to_grading_scheme_summary_json(grading_standard)
        }
      end
    end
  end

  def show_account_default_grading_scheme
    return unless Account.site_admin.feature_enabled?(:default_account_grading_scheme)
    return unless @context.is_a?(Account)
    return unless authorized_action(@context, @current_user, @context.grading_standard_read_permission)

    grading_standard = @context.grading_standard

    respond_to do |format|
      if grading_standard.nil?
        format.json { render json: nil }
      else
        format.json { render json: GradingSchemesJsonController.to_grading_scheme_json(grading_standard, @current_user) }
      end
    end
  end

  def regrade_affected_assignments(assignments, grading_standard)
    regrade_affected_submissions(assignments, grading_standard)
    regrade_affected_submission_versions(assignments, grading_standard)
  end

  def regrade_affected_submissions(assignments, grading_standard)
    submissions_with_grades = Submission.where.not(grade: nil).where(assignment_id: assignments.select(:id))
    submissions_with_grades.preload(assignment: [:grading_standard, { context: :grading_standard }]).find_in_batches(batch_size: 1000) do |submissions_batch|
      batched_updates = submissions_batch.each_with_object([]) do |submission, acc|
        next if submission.assignment.points_possible.zero?

        score = BigDecimal(submission.score.to_s.presence || "0.0") / BigDecimal(submission.assignment.points_possible.to_s)
        new_grade = grading_standard.score_to_grade((score * 100).to_f)
        grade_has_changed = new_grade != submission.grade || new_grade != submission.published_grade
        if grade_has_changed
          acc << submission.attributes.merge("grade" => new_grade, "published_grade" => new_grade, "updated_at" => Time.now)
        end
      end

      Submission.upsert_all(
        batched_updates,
        unique_by: :id,
        update_only: %i[grade published_grade updated_at],
        record_timestamps: false,
        returning: false
      )
    end
  end

  def regrade_affected_submission_versions(assignments, grading_standard)
    current_versions_for_submissions = Version
                                       .where(versionable: Submission.where(assignment: assignments))
                                       .order(versionable_id: :asc, number: :desc)
                                       .distinct_on(:versionable_id) # we only want the _most recent_ version associated with each submission
    ActiveRecord::Base.transaction do
      current_versions_for_submissions.preload(versionable: { assignment: [:grading_standard, { context: :grading_standard }] }).find_each do |version|
        model = version.model
        next unless model.grade.present? && version.versionable.assignment.points_possible.positive?

        score = BigDecimal(model.score.to_s.presence || "0.0") / BigDecimal(model.assignment.points_possible.to_s)
        new_grade = grading_standard.score_to_grade((score * 100).to_f)
        grade_has_changed = new_grade != model.grade || new_grade != model.published_grade
        next unless grade_has_changed

        model.grade = new_grade
        model.published_grade = new_grade
        yaml = model.attributes.to_yaml
        # We can't use the same upsert_all approach that we used in regrade_affected_submissions
        # because the versions table is partitioned.
        version.update_columns(yaml:)
      end
    end
  end

  def recompute_assignments_using_account_default(account, grading_standard)
    account.courses.where(grading_standard_id: nil).where.not(workflow_state: "completed").where.not(workflow_state: "deleted").find_each do |course|
      affected_assignments = course.assignments.where(grading_type: ["letter_grade", "gpa_scale"], grading_standard_id: nil)
      delay_if_production(priority: Delayed::LOWER_PRIORITY, strand: ["recalc_account_default", Shard.current.database_server.id], singleton: "recalc_account_default:#{course.global_id}").regrade_affected_assignments(affected_assignments, grading_standard)
    end

    account.sub_accounts.where(grading_standard: nil).find_each do |sub_account|
      recompute_assignments_using_account_default(sub_account, grading_standard)
    end
  end

  def update_account_default_grading_scheme
    return unless Account.site_admin.feature_enabled?(:default_account_grading_scheme)
    return unless @context.is_a?(Account)
    return unless authorized_action(@context, @current_user, :manage)

    grading_standard = if params[:id].nil?
                         nil
                       else
                         GradingStandard.find(params[:id])
                       end
    @context.grading_standard = grading_standard

    response = if grading_standard.nil?
                 nil
               else
                 GradingSchemesJsonController.to_grading_scheme_json(grading_standard, @current_user)
               end

    respond_to do |format|
      if @context.save
        recompute_assignments_using_account_default(@context, @context.grading_standard)
        format.json { render json: response }
      else
        format.json { render json: @context.errors, status: :bad_request }
      end
    end
  end

  def show
    grading_standard = grading_standards_for_context.find(params[:id])
    respond_to do |format|
      format.json { render json: GradingSchemesJsonController.to_grading_scheme_json(grading_standard, @current_user) }
    end
  end

  def show_default_grading_scheme
    respond_to do |format|
      format.json do
        render json: GradingSchemesJsonController.default_to_json(
          @current_user,
          @context
        )
      end
    end
  end

  def create
    if authorized_action(@context, @current_user, :manage_grades)
      grading_standard = @context.grading_standards.build(grading_scheme_payload)

      respond_to do |format|
        if grading_standard.save
          track_create_metrics(grading_standard)
          format.json { render json: GradingSchemesJsonController.to_grading_scheme_json(grading_standard, @current_user) }
        else
          format.json { render json: grading_standard.errors, status: :bad_request }
        end
      end
    end
  end

  def update
    grading_standard = grading_standards_for_context(include_parent_accounts: false).find(params[:id])
    if authorized_action(grading_standard, @current_user, :manage)
      grading_standard.user = @current_user

      respond_to do |format|
        if grading_standard.update(grading_scheme_payload)
          track_update_metrics(grading_standard)
          format.json { render json: GradingSchemesJsonController.to_grading_scheme_json(grading_standard, @current_user) }
        else
          format.json { render json: grading_standard.errors, status: :bad_request }
        end
      end
    end
  end

  def used_locations
    grading_standard = grading_standards_for_context.find(params[:id])
    return unless authorized_action(grading_standard, @current_user, :manage)

    render json: courses_using(grading_standard)
  end

  def used_locations_for_course
    grading_standard = grading_standards_for_context.find(params[:id])
    return unless authorized_action(grading_standard, @current_user, :manage)

    scope = grading_standard.assignments
                            .where(context_id: params[:course_id], context_type: Course.to_s)
                            .active
                            .select(:title, :context_id, :id)
                            .order(:title)

    assignments = Api.paginate(
      scope,
      self,
      account_grading_schemes_used_locations_for_course_path(
        account_id: @context.id, id: grading_standard.id, course_id: params[:course_id]
      ),
      per_page: USED_LOCATIONS_PER_PAGE
    )

    render json: assignments.map { |assignment| assignment.as_json(only: [:id, :title], include_root: false) }
  end

  def account_used_locations
    grading_standard = grading_standards_for_context.find(params[:id])
    return unless authorized_action(grading_standard, @current_user, :manage)

    render json: accounts_using(grading_standard)
  end

  def archive
    grading_standard = grading_standards_for_context.find(params[:id])
    if authorized_action(grading_standard, @current_user, :manage)
      respond_to do |format|
        if grading_standard.archive!
          track_update_metrics(grading_standard)
          format.json { render json: GradingSchemesJsonController.to_grading_scheme_json(grading_standard, @current_user) }
        else
          if grading_standard.halted_because
            grading_standard.errors.add(:workflow_state, grading_standard.halted_because)
          end

          format.json { render json: grading_standard.errors, status: :bad_request }
        end
      end
    end
  end

  def unarchive
    grading_standard = GradingStandard.archived.for_context(@context).find(params[:id])
    if authorized_action(grading_standard, @current_user, :manage)
      respond_to do |format|
        if grading_standard.unarchive!
          track_update_metrics(grading_standard)
          format.json { render json: GradingSchemesJsonController.to_grading_scheme_json(grading_standard, @current_user) }
        else
          if grading_standard.halted_because
            grading_standard.errors.add(:workflow_state, grading_standard.halted_because)
          end

          format.json { render json: grading_standard.errors, status: :bad_request }
        end
      end
    end
  end

  def destroy
    grading_standard = grading_standards_for_context.find(params[:id])
    if authorized_action(grading_standard, @current_user, :manage)
      respond_to do |format|
        if grading_standard.destroy
          format.json { render json: {} }
        else
          format.json { render json: grading_standard.errors, status: :bad_request }
        end
      end
    end
  end

  def accounts_using(grading_standard)
    GuardRail.activate(:secondary) do
      grading_standard.accounts.order(:name).select(:id, :name).map do |account|
        account.as_json(only: [:id, :name], include_root: false)
      end
    end
  end

  def courses_using(grading_standard)
    GuardRail.activate(:secondary) do
      courses_ids = grading_standard.courses.active.pluck(:id)
      assignments_courses_ids = grading_standard.assignments.active.pluck(:context_id)
      all_courses_ids = (assignments_courses_ids + courses_ids).compact.uniq

      scope = Course.where(id: all_courses_ids).active.order(:name)

      courses = Api.paginate(
        scope,
        self,
        account_grading_schemes_used_locations_path(
          account_id: @context.id, id: grading_standard.id
        ),
        per_page: USED_LOCATIONS_PER_PAGE
      )

      courses.map do |course|
        course_json = course.as_json(only: [:id, :name], methods: [:concluded?], include_root: false)
        course_json[:with_assignments] = assignments_courses_ids.include?(course.id)
        course_json[:assignments] = []
        course_json
      end
    end
  end

  def self.to_grading_standard_data(grading_scheme_json_data)
    # converts a GradingScheme UI model's data field format from:
    # [{"name": "A", "value": .94}, {"name": "B", "value": .84}, ]
    # to the GradingStandard ActiveRecord's data field format:
    # { "A" => 0.94, "B" => .84, }
    grading_standard_data = {}
    grading_scheme_json_data.map do |grading_scheme_data_row|
      grading_standard_data[grading_scheme_data_row["name"]] = grading_scheme_data_row["value"]
    end
    grading_standard_data
  end

  def self.json_serialized_fields
    %w[id title scaling_factor points_based context_type context_id workflow_state]
  end

  def grading_standards_for_context(include_parent_accounts: true)
    include_archived = params[:include_archived] == "true"
    if params[:assignment_id]
      @assignment = @context.assignments.find(params[:assignment_id])
      return GradingStandard.for(@assignment, include_archived:)
    end
    GradingStandard.for(@context, include_archived:, include_parent_accounts:)
  end

  def self.default_canvas_grading_standard(context)
    grading_standard_data = GradingStandard.default_grading_standard
    props = {}
    props["title"] = I18n.t("Default Canvas Grading Scheme")
    props["data"] = grading_standard_data
    props["scaling_factor"] = 1.0
    props["points_based"] = false
    context.grading_standards.build(props)
  end

  private

  def grading_scheme_payload
    { title: params[:title],
      data: GradingSchemesJsonController.to_grading_standard_data(params[:data]),
      points_based: params[:points_based],
      scaling_factor: params[:scaling_factor] }
  end

  def track_update_metrics(grading_standard)
    if grading_standard.changed.include?("points_based")
      InstStatsd::Statsd.increment("grading_scheme.update.points_based") if grading_standard.points_based
      InstStatsd::Statsd.increment("grading_scheme.update.percentage_based") unless grading_standard.points_based
    end
    if grading_standard.changed.include?("workflow_state")
      InstStatsd::Statsd.increment("grading_scheme.update.workflow_archived") if grading_standard.archived
      InstStatsd::Statsd.increment("grading_scheme.update.workflow_active") if grading_standard.active
      InstStatsd::Statsd.increment("grading_scheme.update.workflow_deleted") if grading_standard.deleted
    end
  end

  def track_create_metrics(grading_standard)
    InstStatsd::Statsd.increment("grading_scheme.create.points_based") if grading_standard.points_based
    InstStatsd::Statsd.increment("grading_scheme.create.percentage_based") unless grading_standard.points_based
  end

  def validate_read_permission
    authorized_action(@context, @current_user, @context.grading_standard_read_permission)
  end
end
