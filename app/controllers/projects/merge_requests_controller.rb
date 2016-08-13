class Projects::MergeRequestsController < Projects::ApplicationController
  include ToggleSubscriptionAction
  include DiffForPath
  include DiffHelper
  include IssuableActions
  include NotesHelper
  include ToggleAwardEmoji
  include IssuableCollections

  before_action :module_enabled
  before_action :merge_request, only: [
    :edit, :update, :show, :diffs, :commits, :conflicts, :builds, :pipelines, :merge, :merge_check,
    :ci_status, :toggle_subscription, :cancel_merge_when_build_succeeds, :remove_wip, :resolve_conflicts
  ]
  before_action :validates_merge_request, only: [:show, :diffs, :commits, :builds, :pipelines]
  before_action :define_show_vars, only: [:show, :diffs, :commits, :conflicts, :builds, :pipelines]
  before_action :define_widget_vars, only: [:merge, :cancel_merge_when_build_succeeds, :merge_check]
  before_action :define_commit_vars, only: [:diffs]
  before_action :define_diff_comment_vars, only: [:diffs]
  before_action :ensure_ref_fetched, only: [:show, :diffs, :commits, :builds, :conflicts, :pipelines]

  # Allow read any merge_request
  before_action :authorize_read_merge_request!

  # Allow write(create) merge_request
  before_action :authorize_create_merge_request!, only: [:new, :create]

  # Allow modify merge_request
  before_action :authorize_update_merge_request!, only: [:close, :edit, :update, :remove_wip, :sort]

  before_action :authorize_can_resolve_conflicts!, only: [:conflicts, :resolve_conflicts]

  def index
    terms = params['issue_search']
    @merge_requests = merge_requests_collection

    if terms.present?
      if terms =~ /\A[#!](\d+)\z/
        @merge_requests = @merge_requests.where(iid: $1)
      else
        @merge_requests = @merge_requests.full_search(terms)
      end
    end

    @merge_requests = @merge_requests.page(params[:page])
    @merge_requests = @merge_requests.preload(:target_project)

    @labels = @project.labels.where(title: params[:label_name])

    respond_to do |format|
      format.html
      format.json do
        render json: {
          html: view_to_html_string("projects/merge_requests/_merge_requests"),
          labels: @labels.as_json(methods: :text_color)
        }
      end
    end
  end

  def show
    respond_to do |format|
      format.html { define_discussion_vars }

      format.json do
        render json: @merge_request
      end

      format.patch  do
        return render_404 unless @merge_request.diff_refs

        send_git_patch @project.repository, @merge_request.diff_refs
      end

      format.diff do
        return render_404 unless @merge_request.diff_refs

        send_git_diff @project.repository, @merge_request.diff_refs
      end
    end
  end

  def diffs
    apply_diff_view_cookie!

    @merge_request_diff =
      if params[:diff_id]
        @merge_request.merge_request_diffs.find(params[:diff_id])
      else
        @merge_request.merge_request_diff
      end

    @merge_request_diffs = @merge_request.merge_request_diffs.select_without_diff
    @comparable_diffs = @merge_request_diffs.select { |diff| diff.id < @merge_request_diff.id }

    if params[:start_sha].present?
      @start_sha = params[:start_sha]
      @start_version = @comparable_diffs.find { |diff| diff.head_commit_sha == @start_sha }

      unless @start_version
        render_404
      end
    end

    respond_to do |format|
      format.html { define_discussion_vars }
      format.json do
        if @start_sha
          compared_diff_version
        else
          original_diff_version
        end

        render json: { html: view_to_html_string("projects/merge_requests/show/_diffs") }
      end
    end
  end

  # With an ID param, loads the MR at that ID. Otherwise, accepts the same params as #new
  # and uses that (unsaved) MR.
  #
  def diff_for_path
    if params[:id]
      merge_request
      define_diff_comment_vars
    else
      build_merge_request
      @diff_notes_disabled = true
      @grouped_diff_discussions = {}
    end

    define_commit_vars

    render_diff_for_path(@merge_request.diffs(diff_options))
  end

  def commits
    respond_to do |format|
      format.html do
        define_discussion_vars

        render 'show'
      end
      format.json do
        # Get commits from repository
        # or from cache if already merged
        @commits = @merge_request.commits
        @note_counts = Note.where(commit_id: @commits.map(&:id)).
          group(:commit_id).count

        render json: { html: view_to_html_string('projects/merge_requests/show/_commits') }
      end
    end
  end

  def conflicts
    respond_to do |format|
      format.html { define_discussion_vars }

      format.json do
        if @merge_request.conflicts_can_be_resolved_in_ui?
          render json: @merge_request.conflicts
        elsif @merge_request.can_be_merged?
          render json: {
            message: 'The merge conflicts for this merge request have already been resolved. Please return to the merge request.',
            type: 'error'
          }
        else
          render json: {
            message: 'The merge conflicts for this merge request cannot be resolved through GitLab. Please try to resolve them locally.',
            type: 'error'
          }
        end
      end
    end
  end

  def resolve_conflicts
    return render_404 unless @merge_request.conflicts_can_be_resolved_in_ui?

    if @merge_request.can_be_merged?
      render status: :bad_request, json: { message: 'The merge conflicts for this merge request have already been resolved.' }
      return
    end

    begin
      MergeRequests::ResolveService.new(@merge_request.source_project, current_user, params).execute(@merge_request)

      flash[:notice] = 'All merge conflicts were resolved. The merge request can now be merged.'

      render json: { redirect_to: namespace_project_merge_request_url(@project.namespace, @project, @merge_request, resolved_conflicts: true) }
    rescue Gitlab::Conflict::File::MissingResolution => e
      render status: :bad_request, json: { message: e.message }
    end
  end

  def builds
    respond_to do |format|
      format.html do
        define_discussion_vars

        render 'show'
      end
      format.json { render json: { html: view_to_html_string('projects/merge_requests/show/_builds') } }
    end
  end

  def pipelines
    @pipelines = @merge_request.all_pipelines

    respond_to do |format|
      format.html do
        define_discussion_vars

        render 'show'
      end
      format.json { render json: { html: view_to_html_string('projects/merge_requests/show/_pipelines') } }
    end
  end

  def new
    apply_diff_view_cookie!

    build_merge_request
    @noteable = @merge_request

    @target_branches = if @merge_request.target_project
                         @merge_request.target_project.repository.branch_names
                       else
                         []
                       end

    @target_project = merge_request.target_project
    @source_project = merge_request.source_project
    @commits = @merge_request.compare_commits.reverse
    @commit = @merge_request.diff_head_commit
    @base_commit = @merge_request.diff_base_commit
    @diffs = @merge_request.diffs(diff_options) if @merge_request.compare
    @diff_notes_disabled = true
    @pipeline = @merge_request.pipeline
    @statuses = @pipeline.statuses.relevant if @pipeline

    @note_counts = Note.where(commit_id: @commits.map(&:id)).
      group(:commit_id).count
  end

  def create
    @target_branches ||= []
    @merge_request = MergeRequests::CreateService.new(project, current_user, merge_request_params).execute

    if @merge_request.valid?
      redirect_to(merge_request_path(@merge_request))
    else
      @source_project = @merge_request.source_project
      @target_project = @merge_request.target_project
      render action: "new"
    end
  end

  def edit
    @source_project = @merge_request.source_project
    @target_project = @merge_request.target_project
    @target_branches = @merge_request.target_project.repository.branch_names
  end

  def update
    @merge_request = MergeRequests::UpdateService.new(project, current_user, merge_request_params).execute(@merge_request)

    if @merge_request.valid?
      respond_to do |format|
        format.html do
          redirect_to([@merge_request.target_project.namespace.becomes(Namespace),
                       @merge_request.target_project, @merge_request])
        end
        format.json do
          render json: @merge_request.to_json(include: { milestone: {}, assignee: { methods: :avatar_url }, labels: { methods: :text_color } })
        end
      end
    else
      render "edit"
    end
  rescue ActiveRecord::StaleObjectError
    @conflict = true
    render :edit
  end

  def remove_wip
    MergeRequests::UpdateService.new(project, current_user, title: @merge_request.wipless_title).execute(@merge_request)

    redirect_to namespace_project_merge_request_path(@project.namespace, @project, @merge_request),
      notice: "The merge request can now be merged."
  end

  def merge_check
    @merge_request.check_if_can_be_merged

    render partial: "projects/merge_requests/widget/show.html.haml", layout: false
  end

  def cancel_merge_when_build_succeeds
    return access_denied! unless @merge_request.can_cancel_merge_when_build_succeeds?(current_user)

    MergeRequests::MergeWhenBuildSucceedsService.new(@project, current_user).cancel(@merge_request)

    render partial: 'projects/merge_requests/widget/open/accept', layout: false
  end

  def merge
    return access_denied! unless @merge_request.can_be_merged_by?(current_user)

    # Disable the CI check if merge_when_build_succeeds is enabled since we have
    # to wait until CI completes to know
    unless @merge_request.mergeable?(skip_ci_check: merge_when_build_succeeds_active?)
      @status = :failed
      return render_widget(@status)
    end

    if params[:sha] != @merge_request.diff_head_sha
      @status = :sha_mismatch
      return render_widget(@status)
    end

    TodoService.new.merge_merge_request(merge_request, current_user)

    @merge_request.update(merge_error: nil)

    if params[:merge_when_build_succeeds].present?
      unless @merge_request.pipeline
        @status = :failed
        return render_widget(@status)
      end

      if @merge_request.pipeline.active?
        MergeRequests::MergeWhenBuildSucceedsService.new(@project, current_user, merge_params)
                                                        .execute(@merge_request)
        @status = :merge_when_build_succeeds
      elsif @merge_request.pipeline.success?
        # This can be triggered when a user clicks the auto merge button while
        # the tests finish at about the same time
        MergeWorker.perform_async(@merge_request.id, current_user.id, params)
        @status = :success
      else
        @status = :failed
      end
    else
      MergeWorker.perform_async(@merge_request.id, current_user.id, params)
      @status = :success
    end

    render_widget(@status)
  end

  def render_widget(status)
    case status
    when :success
      render json: { merge_in_progress: params[:should_remove_source_branch] == '1' }
    when :merge_when_build_succeeds
      render partial: 'projects/merge_requests/widget/open/merge_when_build_succeeds', layout: false
    when :sha_mismatch
      render partial: 'projects/merge_requests/widget/open/sha_mismatch', layout: false
    else
      render partial: 'projects/merge_requests/widget/open/reload', layout: false
    end
  end

  def branch_from
    # This is always source
    @source_project = @merge_request.nil? ? @project : @merge_request.source_project
    @commit = @repository.commit(params[:ref]) if params[:ref].present?
    render layout: false
  end

  def branch_to
    @target_project = selected_target_project
    @commit = @target_project.commit(params[:ref]) if params[:ref].present?
    render layout: false
  end

  def update_branches
    @target_project = selected_target_project
    @target_branches = @target_project.repository.branch_names

    render layout: false
  end

  def ci_status
    pipeline = @merge_request.pipeline
    if pipeline
      status = pipeline.status
      coverage = pipeline.try(:coverage)

      status = "success_with_warnings" if pipeline.success? && pipeline.has_warnings?

      status ||= "preparing"
    else
      ci_service = @merge_request.source_project.ci_service
      status = ci_service.commit_status(merge_request.diff_head_sha, merge_request.source_branch) if ci_service

      if ci_service.respond_to?(:commit_coverage)
        coverage = ci_service.commit_coverage(merge_request.diff_head_sha, merge_request.source_branch)
      end
    end

    response = {
      title: merge_request.title,
      sha: merge_request.diff_head_commit.short_id,
      status: status,
      coverage: coverage
    }

    render json: response
  end

  protected

  def selected_target_project
    if @project.id.to_s == params[:target_project_id] || @project.forked_project_link.nil?
      @project
    else
      @project.forked_project_link.forked_from_project
    end
  end

  def merge_request
    @issuable = @merge_request ||= @project.merge_requests.find_by!(iid: params[:id])
  end
  alias_method :subscribable_resource, :merge_request
  alias_method :issuable, :merge_request
  alias_method :awardable, :merge_request

  def authorize_update_merge_request!
    return render_404 unless can?(current_user, :update_merge_request, @merge_request)
  end

  def authorize_admin_merge_request!
    return render_404 unless can?(current_user, :admin_merge_request, @merge_request)
  end

  def authorize_can_resolve_conflicts!
    return render_404 unless @merge_request.conflicts_can_be_resolved_by?(current_user)
  end

  def module_enabled
    return render_404 unless @project.feature_available?(:merge_requests, current_user)
  end

  def validates_merge_request
    # If source project was removed (Ex. mr from fork to origin)
    return invalid_mr unless @merge_request.source_project

    # Show git not found page
    # if there is no saved commits between source & target branch
    if @merge_request.commits.blank?
      # and if target branch doesn't exist
      return invalid_mr unless @merge_request.target_branch_exists?

      # or if source branch doesn't exist
      return invalid_mr unless @merge_request.source_branch_exists?
    end
  end

  def define_show_vars
    @noteable = @merge_request
    @commits_count = @merge_request.commits.count

    @pipeline = @merge_request.pipeline
    @statuses = @pipeline.statuses.relevant if @pipeline

    if @merge_request.locked_long_ago?
      @merge_request.unlock_mr
      @merge_request.close
    end
  end

  # Discussion tab data is rendered on html responses of actions
  # :show, :diff, :commits, :builds. but not when request the data through AJAX
  def define_discussion_vars
    # Build a note object for comment form
    @note = @project.notes.new(noteable: @merge_request)

    @discussions = @merge_request.discussions

    preload_noteable_for_regular_notes(@discussions.flat_map(&:notes))

    # This is not executed lazily
    @notes = Banzai::NoteRenderer.render(
      @discussions.flat_map(&:notes),
      @project,
      current_user,
      @path,
      @project_wiki,
      @ref
    )

    preload_max_access_for_authors(@notes, @project)
  end

  def define_widget_vars
    @pipeline = @merge_request.pipeline
    @pipelines = [@pipeline].compact
  end

  def define_commit_vars
    @commit = @merge_request.diff_head_commit
    @base_commit = @merge_request.diff_base_commit || @merge_request.likely_diff_base_commit
  end

  def define_diff_comment_vars
    @comments_target = {
      noteable_type: 'MergeRequest',
      noteable_id: @merge_request.id
    }

    @use_legacy_diff_notes = !@merge_request.has_complete_diff_refs?
    @grouped_diff_discussions = @merge_request.notes.inc_relations_for_view.grouped_diff_discussions

    Banzai::NoteRenderer.render(
      @grouped_diff_discussions.values.flat_map(&:notes),
      @project,
      current_user,
      @path,
      @project_wiki,
      @ref
    )
  end

  def invalid_mr
    # Render special view for MR with removed source or target branch
    render 'invalid'
  end

  def merge_request_params
    params.require(:merge_request).permit(
      :title, :assignee_id, :source_project_id, :source_branch,
      :target_project_id, :target_branch, :milestone_id,
      :state_event, :description, :task_num, :force_remove_source_branch,
      :lock_version, label_ids: []
    )
  end

  def merge_params
    params.permit(:should_remove_source_branch, :commit_message)
  end

  # Make sure merge requests created before 8.0
  # have head file in refs/merge-requests/
  def ensure_ref_fetched
    @merge_request.ensure_ref_fetched
  end

  def merge_when_build_succeeds_active?
    params[:merge_when_build_succeeds].present? &&
      @merge_request.pipeline && @merge_request.pipeline.active?
  end

  def build_merge_request
    params[:merge_request] ||= ActionController::Parameters.new(source_project: @project)
    @merge_request = MergeRequests::BuildService.new(project, current_user, merge_request_params).execute
  end

  def compared_diff_version
    @diff_notes_disabled = true
    @diffs = @merge_request_diff.compare_with(@start_sha).diffs(diff_options)
  end

  def original_diff_version
    @diff_notes_disabled = !@merge_request_diff.latest?
    @diffs = @merge_request_diff.diffs(diff_options)
  end
end
