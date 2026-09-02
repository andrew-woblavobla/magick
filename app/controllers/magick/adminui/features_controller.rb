# frozen_string_literal: true

module Magick
  module AdminUI
    class FeaturesController < ActionController::Base
      # Inheriting ActionController::Base does NOT bring in CSRF protection.
      # Include RequestForgeryProtection + explicit protect_from_forgery so
      # cross-site form submissions cannot toggle flags behind a logged-in
      # admin's back.
      include ::ActionController::RequestForgeryProtection
      protect_from_forgery with: :exception

      # Include route helpers so views can use magick_admin_ui.* helpers
      include Magick::AdminUI::Engine.routes.url_helpers
      layout 'application'
      # Installs the shared `authenticate_admin!` filter. Included (rather
      # than declared here) so every Admin UI controller is gated by the same
      # `require_role` hook — see Magick::AdminUI::Authentication.
      include Magick::AdminUI::Authentication
      before_action :set_feature, only: %i[show edit update enable disable enable_for_user enable_for_role disable_for_role update_targeting update_variants]
      # Attribute every change made during the request to the configured
      # actor, so audit entries and version snapshots record who did it.
      around_action :with_magick_actor
      # Render the TRUE current state, not this process's local cache. In a
      # multi-process / multi-container deployment the enable/disable POST and
      # the redirected GET are load-balanced to different processes, so the
      # process rendering the page may hold a stale memory copy until Pub/Sub
      # catches up. These refresh from the shared backend before rendering.
      before_action :refresh_all_features_from_source, only: %i[index]
      before_action :refresh_feature_from_source, only: %i[show edit]

      # Make route helpers available in views via magick_admin_ui helper
      helper_method :magick_admin_ui, :available_roles, :available_tags, :partially_enabled?

      def magick_admin_ui
        Magick::AdminUI::Engine.routes.url_helpers
      end

      def available_roles
        Magick::AdminUI.config.available_roles || []
      end

      def available_tags
        Magick::AdminUI.config.tags
      end

      def partially_enabled?(feature)
        (feature.targeting || {}).any?
      end

      def index
        @features = Magick.features.values

        # Filter by group if provided
        if params[:group].present?
          @features = @features.select { |f| f.group == params[:group] }
        end

        # Filter by search query (name or description)
        if params[:search].present?
          search_term = params[:search].downcase
          @features = @features.select do |f|
            f.name.downcase.include?(search_term) ||
            (f.display_name && f.display_name.downcase.include?(search_term)) ||
            (f.description && f.description.downcase.include?(search_term))
          end
        end

        # Get all available groups for filter dropdown
        @available_groups = Magick.features.values.map(&:group).compact.uniq.sort
      end

      def show
      end

      def edit
      end

      def update
        # Update group if provided
        if params.key?(:group)
          @feature.set_group(params[:group])
        end

        if @feature.type == :boolean
          # For boolean features, checkbox sends 'true' when checked, nothing when unchecked
          # Rails form helpers handle this - if checkbox is unchecked, params[:value] will be nil
          value = params[:value] == 'true'
          @feature.set_value(value)
        elsif params[:value].present?
          # For string/number features, convert to appropriate type
          value = params[:value]
          if @feature.type == :number
            value = value.include?('.') ? value.to_f : value.to_i
          end
          @feature.set_value(value)
        end
        redirect_to magick_admin_ui.feature_path(@feature.name), notice: 'Feature updated successfully'
      end

      def enable
        @feature.enable
        redirect_to magick_admin_ui.features_path, notice: 'Feature enabled'
      end

      def disable
        @feature.disable
        redirect_to magick_admin_ui.features_path, notice: 'Feature disabled'
      end

      def enable_for_user
        @feature.enable_for_user(params[:user_id])
        redirect_to magick_admin_ui.feature_path(@feature.name), notice: 'Feature enabled for user'
      end

      def enable_for_role
        role = params[:role]
        if role.present?
          @feature.enable_for_role(role)
          redirect_to magick_admin_ui.feature_path(@feature.name), notice: "Feature enabled for role: #{role}"
        else
          redirect_to magick_admin_ui.feature_path(@feature.name), alert: 'Role is required'
        end
      end

      def disable_for_role
        role = params[:role]
        if role.present?
          @feature.disable_for_role(role)
          redirect_to magick_admin_ui.feature_path(@feature.name), notice: "Feature disabled for role: #{role}"
        else
          redirect_to magick_admin_ui.feature_path(@feature.name), alert: 'Role is required'
        end
      end

      def update_targeting
        targeting_params = params[:targeting] || {}
        unless hash_like?(targeting_params)
          redirect_to magick_admin_ui.feature_path(@feature.name), alert: 'Invalid targeting payload.'
          return
        end

        # Ensure we're using the registered feature instance
        feature_name = @feature.name.to_s
        @feature = Magick.features[feature_name] if Magick.features.key?(feature_name)

        # One declarative write: one audit entry + one version per submit.
        @feature.replace_targeting(desired_targeting_from_form(targeting_params))
        @feature.reload

        redirect_to magick_admin_ui.feature_path(@feature.name), notice: 'Targeting updated successfully'
      rescue Magick::InvalidTargetingError => e
        redirect_to magick_admin_ui.feature_path(@feature.name), alert: "Invalid targeting: #{e.message}"
      rescue StandardError => e
        Rails.logger.error "Magick: Error updating targeting for #{@feature.name}: #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}" if defined?(Rails)
        redirect_to magick_admin_ui.feature_path(@feature.name), alert: 'Could not update targeting — see server logs for details.'
      end

      def update_variants
        variants_data = []

        if params[:variants].present? && !hash_like?(params[:variants])
          redirect_to magick_admin_ui.feature_path(@feature.name), alert: 'Invalid variants payload.'
          return
        end

        if params[:variants].present?
          params[:variants].each do |_index, variant_params|
            next if variant_params[:name].blank?

            variants_data << {
              name: variant_params[:name].strip,
              value: variant_params[:value].to_s.strip,
              weight: (variant_params[:weight].presence || 0).to_f
            }
          end
        end

        if variants_data.any?
          @feature.set_variants(variants_data)
        else
          # Clear variants if all removed
          @feature.instance_variable_get(:@targeting)&.delete(:variants)
          @feature.save_targeting
        end

        redirect_to magick_admin_ui.feature_path(@feature.name), notice: 'Variants updated successfully'
      rescue StandardError => e
        Rails.logger.error "Magick: Error updating variants for #{@feature.name}: #{e.class}: #{e.message}" if defined?(Rails)
        redirect_to magick_admin_ui.feature_path(@feature.name), alert: 'Could not update variants — see server logs for details.'
      end

      # Targeting rules the edit form has no fields for. They are carried over
      # from the current state on every submit so a form save can never
      # silently destroy them. (:variants is preserved by replace_targeting
      # itself.)
      FORM_UNMANAGED_TARGETING_KEYS = %i[
        group excluded_groups ip_address excluded_ip_addresses
        date_range custom_attributes complex_conditions
      ].freeze

      private

      # Build the full desired targeting state from the edit form. Checkbox
      # groups (roles/tags and their exclusions) and the percentage fields are
      # authoritative on every submit — unchecked/blank means "remove the
      # rule". The comma-separated user lists are only authoritative when
      # their field was actually sent. Percentages stay lenient here (blank
      # or out-of-range clears the rule, as the form always behaved) —
      # strict validation is for API callers of replace_targeting.
      def desired_targeting_from_form(targeting_params)
        current = @feature.targeting || {}
        desired = {}
        FORM_UNMANAGED_TARGETING_KEYS.each { |key| desired[key] = current[key] if current.key?(key) }

        desired[:role] = Array(targeting_params[:roles]).reject(&:blank?)
        desired[:tag] = Array(targeting_params[:tags]).reject(&:blank?)
        desired[:excluded_roles] = Array(targeting_params[:excluded_roles]).reject(&:blank?)
        desired[:excluded_tags] = Array(targeting_params[:excluded_tags]).reject(&:blank?)

        desired[:user] = csv_ids(targeting_params, :user_ids, current[:user])
        desired[:excluded_users] = csv_ids(targeting_params, :excluded_user_ids, current[:excluded_users])

        desired[:percentage_users] = form_percentage(targeting_params[:percentage_users])
        desired[:percentage_requests] = form_percentage(targeting_params[:percentage_requests])

        desired.compact
      end

      def csv_ids(targeting_params, field, current_value)
        return Array(current_value) unless targeting_params.key?(field)

        targeting_params[field].to_s.split(',').map(&:strip).reject(&:blank?)
      end

      def form_percentage(raw)
        return nil if raw.blank?

        percentage = raw.to_f
        percentage.positive? && percentage <= 100 ? percentage : nil
      end

      # Resolve the acting admin via the configurable AdminUI hook and run the
      # action inside Magick.with_actor. A failing resolver only costs
      # attribution — it must never 500 the admin UI, and it is rescued
      # separately so an action error is never swallowed or re-run.
      def with_magick_actor(&block)
        actor = begin
          resolver = Magick::AdminUI.config.current_actor
          resolver.respond_to?(:call) ? resolver.call(self) : nil
        rescue StandardError => e
          Rails.logger.warn "Magick: current_actor hook failed: #{e.class}: #{e.message}" if defined?(Rails)
          nil
        end

        actor ? Magick.with_actor(actor, &block) : yield
      end

      # A hash-like payload is either a raw Hash or an
      # ActionController::Parameters (both respond to :each with key/value).
      # Rejecting anything else lets us give a 400-style redirect instead of
      # a 500 with a NoMethodError stack trace.
      def hash_like?(obj)
        obj.is_a?(Hash) || (defined?(ActionController::Parameters) && obj.is_a?(ActionController::Parameters))
      end

      # Refresh every registered feature from the shared backend so the index
      # reflects authoritative state regardless of which container serves it.
      # Best-effort: a backend hiccup must never 500 the admin list.
      def refresh_all_features_from_source
        registry = Magick.adapter_registry
        registry.refresh_all_from_source if registry.respond_to?(:refresh_all_from_source)
        Magick.features.each_value { |f| f.reload if f.respond_to?(:reload) }
      rescue StandardError => e
        Rails.logger.warn "Magick: admin source refresh failed: #{e.class}: #{e.message}" if defined?(Rails)
      end

      # Refresh the single feature being viewed/edited from the shared backend.
      def refresh_feature_from_source
        return unless @feature

        @feature.reload_from_source! if @feature.respond_to?(:reload_from_source!)
      rescue StandardError => e
        Rails.logger.warn "Magick: admin source refresh failed: #{e.class}: #{e.message}" if defined?(Rails)
      end

      def set_feature
        feature_name = params[:id].to_s
        # Do NOT fall back to Magick[feature_name] — that would lazily create
        # and persist a brand-new feature from user-controlled input, letting
        # an attacker (or even a stray crawler) pollute Redis/AR with arbitrary
        # keys. Look up only registered features; 404 otherwise.
        @feature = Magick.features[feature_name]
        return if @feature

        redirect_to magick_admin_ui.features_path, alert: 'Feature not found'
        nil
      end
    end
  end
end
