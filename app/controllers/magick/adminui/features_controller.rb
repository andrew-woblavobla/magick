# frozen_string_literal: true

module Magick
  module AdminUI
    class FeaturesController < ActionController::Base
      # Include route helpers so views can use magick_admin_ui.* helpers
      include Magick::AdminUI::Engine.routes.url_helpers
      layout 'application'
      before_action :set_feature, only: %i[show edit update enable disable enable_for_user enable_for_role disable_for_role update_targeting]

      # Make route helpers available in views via magick_admin_ui helper
      helper_method :magick_admin_ui, :available_roles, :partially_enabled?

      def magick_admin_ui
        Magick::AdminUI::Engine.routes.url_helpers
      end

      def available_roles
        Magick::AdminUI.config.available_roles || []
      end

      def partially_enabled?(feature)
        targeting = feature.instance_variable_get(:@targeting) || {}
        targeting.any? && !targeting.empty?
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
        # Handle targeting updates from form
        targeting_params = params[:targeting] || {}

        # Ensure we're using the registered feature instance
        feature_name = @feature.name.to_s
        @feature = Magick.features[feature_name] if Magick.features.key?(feature_name)

        current_targeting = @feature.instance_variable_get(:@targeting) || {}

        # Handle roles - always clear existing and set new ones
        # Rails checkboxes don't send unchecked values, so we need to check what was sent
        current_roles = current_targeting[:role].is_a?(Array) ? current_targeting[:role] : (current_targeting[:role] ? [current_targeting[:role]] : [])
        selected_roles = Array(targeting_params[:roles]).reject(&:blank?)

        # Disable roles that are no longer selected
        (current_roles - selected_roles).each do |role|
          @feature.disable_for_role(role) if role.present?
        end

        # Enable newly selected roles
        (selected_roles - current_roles).each do |role|
          @feature.enable_for_role(role) if role.present?
        end

        # Handle user IDs - replace existing user targeting
        if targeting_params[:user_ids].present?
          user_ids = targeting_params[:user_ids].split(',').map(&:strip).reject(&:blank?)
          current_user_ids = current_targeting[:user].is_a?(Array) ? current_targeting[:user] : (current_targeting[:user] ? [current_targeting[:user]] : [])

          # Disable users that are no longer in the list
          (current_user_ids - user_ids).each do |user_id|
            @feature.disable_for_user(user_id) if user_id.present?
          end

          # Enable new users
          (user_ids - current_user_ids).each do |user_id|
            @feature.enable_for_user(user_id) if user_id.present?
          end
        elsif targeting_params.key?(:user_ids) && targeting_params[:user_ids].blank?
          # Clear all user targeting if field was cleared
          current_user_ids = current_targeting[:user].is_a?(Array) ? current_targeting[:user] : (current_targeting[:user] ? [current_targeting[:user]] : [])
          current_user_ids.each do |user_id|
            @feature.disable_for_user(user_id) if user_id.present?
          end
        end

        # Handle percentage of users
        percentage_users_value = targeting_params[:percentage_users]
        if percentage_users_value.present? && percentage_users_value.to_s.strip != ''
          percentage = percentage_users_value.to_f
          if percentage > 0 && percentage <= 100
            result = @feature.enable_percentage_of_users(percentage)
            Rails.logger.debug "Magick: Enabled percentage_users #{percentage} for #{@feature.name}: #{result}" if defined?(Rails)
          else
            # Value is 0 or invalid - disable
            @feature.disable_percentage_of_users
          end
        else
          # Field is empty - disable if it was previously set
          @feature.disable_percentage_of_users if current_targeting[:percentage_users]
        end

        # Handle percentage of requests
        percentage_requests_value = targeting_params[:percentage_requests]
        if percentage_requests_value.present? && percentage_requests_value.to_s.strip != ''
          percentage = percentage_requests_value.to_f
          if percentage > 0 && percentage <= 100
            result = @feature.enable_percentage_of_requests(percentage)
            Rails.logger.debug "Magick: Enabled percentage_requests #{percentage} for #{@feature.name}: #{result}" if defined?(Rails)
          else
            # Value is 0 or invalid - disable
            @feature.disable_percentage_of_requests
          end
        else
          # Field is empty - disable if it was previously set
          @feature.disable_percentage_of_requests if current_targeting[:percentage_requests]
        end

        # After all targeting updates, ensure we're using the registered feature instance
        # and reload it to get the latest state from adapter
        feature_name = @feature.name.to_s
        if Magick.features.key?(feature_name)
          @feature = Magick.features[feature_name]
          @feature.reload
        else
          @feature.reload
        end

        redirect_to magick_admin_ui.feature_path(@feature.name), notice: 'Targeting updated successfully'
      rescue StandardError => e
        Rails.logger.error "Magick: Error updating targeting: #{e.message}\n#{e.backtrace.first(5).join("\n")}" if defined?(Rails)
        redirect_to magick_admin_ui.feature_path(@feature.name), alert: "Error updating targeting: #{e.message}"
      end

      private

      def set_feature
        feature_name = params[:id].to_s
        @feature = Magick.features[feature_name] || Magick[feature_name]
        redirect_to magick_admin_ui.features_path, alert: 'Feature not found' unless @feature

        # Ensure we're working with the registered feature instance to keep state in sync
        @feature = Magick.features[feature_name] if Magick.features.key?(feature_name)
      end
    end
  end
end
