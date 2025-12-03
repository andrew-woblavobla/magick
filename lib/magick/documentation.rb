# frozen_string_literal: true

module Magick
  class Documentation
    class << self
      def generate(format: :markdown)
        features = Magick.features.values
        case format.to_sym
        when :markdown
          generate_markdown(features)
        when :html
          generate_html(features)
        when :json
          generate_json(features)
        else
          raise ArgumentError, "Unknown format: #{format}"
        end
      end

      def generate_markdown(features = nil)
        features ||= Magick.features.values
        output = ["# Feature Flags Documentation\n", "Generated: #{Time.now}\n\n"]

        features.each do |feature|
          output << "## #{feature.display_name || feature.name}\n\n"
          output << "**Name:** `#{feature.name}`\n\n"
          output << "**Type:** #{feature.type.to_s.capitalize}\n\n"
          output << "**Status:** #{feature.status.to_s.capitalize}\n\n"
          output << "**Default Value:** `#{feature.default_value.inspect}`\n\n"
          output << "**Description:** #{feature.description || 'No description'}\n\n"

          # Access targeting via instance_variable_get since it's private
          targeting = feature.instance_variable_get(:@targeting) || {}
          if targeting.any?
            output << "### Targeting Rules\n\n"
            targeting.each do |key, value|
              case key.to_sym
              when :user
                user_list = value.is_a?(Array) ? value : [value]
                user_list.each do |user_id|
                  output << "- **user_id:** #{user_id}\n"
                end
              when :group
                group_list = value.is_a?(Array) ? value : [value]
                group_list.each do |group|
                  output << "- **group:** #{group}\n"
                end
              when :role
                role_list = value.is_a?(Array) ? value : [value]
                role_list.each do |role|
                  output << "- **role:** #{role}\n"
                end
              when :percentage_users
                output << "- **percentage_users:** #{value}%\n"
              when :percentage_requests
                output << "- **percentage_requests:** #{value}%\n"
              else
                output << "- **#{key}:** #{value.inspect}\n"
              end
            end
            output << "\n"
          end

          if feature.dependencies.any?
            output << "### Dependencies\n\n"
            feature.dependencies.each do |dep|
              output << "- `#{dep}`\n"
            end
            output << "\n"
          end

          output << "---\n\n"
        end

        output.join
      end

      def generate_html(features = nil)
        features ||= Magick.features.values
        html = <<~HTML
          <!DOCTYPE html>
          <html>
          <head>
            <title>Feature Flags Documentation</title>
            <style>
              body { font-family: Arial, sans-serif; margin: 20px; }
              table { border-collapse: collapse; width: 100%; margin: 20px 0; }
              th, td { border: 1px solid #ddd; padding: 8px; text-align: left; }
              th { background-color: #f2f2f2; }
              .status-active { color: green; }
              .status-deprecated { color: orange; }
              .status-inactive { color: red; }
            </style>
          </head>
          <body>
            <h1>Feature Flags Documentation</h1>
            <p>Generated: #{Time.now}</p>
            <table>
              <thead>
                <tr>
                  <th>Name</th>
                  <th>Type</th>
                  <th>Status</th>
                  <th>Default Value</th>
                  <th>Description</th>
                </tr>
              </thead>
              <tbody>
        HTML

        features.each do |feature|
          html << <<~HTML
            <tr>
              <td><code>#{feature.name}</code></td>
              <td>#{feature.type.to_s.capitalize}</td>
              <td class="status-#{feature.status}">#{feature.status.to_s.capitalize}</td>
              <td><code>#{feature.default_value.inspect}</code></td>
              <td>#{feature.description || 'No description'}</td>
            </tr>
          HTML
        end

        html << <<~HTML
              </tbody>
            </table>
          </body>
          </html>
        HTML

        html
      end

      def generate_json(features = nil)
        features ||= Magick.features.values
        features_data = features.map do |feature|
          # Use to_h to get all feature data including targeting
          feature_hash = feature.to_h
          {
            name: feature_hash[:name],
            display_name: feature_hash[:display_name],
            type: feature_hash[:type].to_s,
            status: feature_hash[:status].to_s,
            default_value: feature_hash[:default_value],
            description: feature_hash[:description],
            targeting: feature_hash[:targeting] || {},
            dependencies: feature.dependencies
          }
        end
        JSON.pretty_generate(features_data)
      end
    end
  end
end
