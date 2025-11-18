# Rails 8.1+ Structured Event Reporting

Magick integrates with Rails 8.1+ Structured Event Reporting (`Rails.event.notify`) to emit structured events for all feature flag operations. This allows you to subscribe to and monitor feature flag activity in your Rails application.

> **Note**: This feature requires Rails 8.1+ which introduced the Structured Event Reporting system. See [Rails 8.1 release notes](https://rubyonrails.org/2025/10/22/rails-8-1) for more information.

## Available Events

All events are prefixed with `magick.feature_flag.`:

- `magick.feature_flag.changed` - Feature value or status changed
- `magick.feature_flag.enabled` - Feature was checked and enabled
- `magick.feature_flag.disabled` - Feature was checked and disabled
- `magick.feature_flag.dependency_added` - Dependency added to feature
- `magick.feature_flag.dependency_removed` - Dependency removed from feature
- `magick.feature_flag.variant_set` - Variants configured for feature
- `magick.feature_flag.variant_selected` - Variant selected for user/request
- `magick.feature_flag.targeting_added` - Targeting rule added
- `magick.feature_flag.targeting_removed` - Targeting rule removed
- `magick.feature_flag.version_saved` - Feature version saved
- `magick.feature_flag.rollback` - Feature rolled back to previous version
- `magick.feature_flag.exported` - Features exported
- `magick.feature_flag.imported` - Features imported
- `magick.feature_flag.audit_logged` - Audit log entry created
- `magick.feature_flag.usage_tracked` - Feature usage tracked
- `magick.feature_flag.deprecated_warning` - Deprecated feature used

## Usage

### Register a Subscriber

Rails 8.1+ uses subscribers that implement the `#emit` method. Create a custom subscriber:

```ruby
# In config/initializers/magick.rb
class MagickEventSubscriber
  def emit(event)
    # event is a hash with :name, :payload, :source_location, :tags, :context
    Rails.logger.info "Magick Event: #{event[:name]}"
    Rails.logger.info "Payload: #{event[:payload].inspect}"

    # Send to monitoring service, analytics, etc.
    Analytics.track(event[:name], event[:payload])
  end
end

# Register subscriber for all Magick events
Magick::Rails::Events::EVENTS.each_value do |event_name|
  Rails.event.subscribe(event_name, MagickEventSubscriber.new)
end
```

### Use the Default Log Subscriber

Magick provides a default log subscriber:

```ruby
# In config/initializers/magick.rb
Magick::Rails::Events::EVENTS.each_value do |event_name|
  Rails.event.subscribe(event_name, Magick::Rails::LogSubscriber.new)
end
```

### Subscribe to Specific Events

```ruby
# Subscribe to specific events only
Rails.event.subscribe('magick.feature_flag.changed', MagickEventSubscriber.new)
Rails.event.subscribe('magick.feature_flag.enabled', MagickEventSubscriber.new)
```

### Using Tags and Context

Rails 8.1+ events support tags and context. Magick events can be tagged:

```ruby
Rails.event.tagged("magick", "feature_flags") do
  # All events in this block will have tags: { magick: true, feature_flags: true }
  feature.set_value(true)
end

# Set context that will be included in all events
Rails.event.set_context(request_id: request.uuid, user_id: current_user.id)
```

## Event Payloads

### feature_changed
```ruby
{
  feature_name: "new_dashboard",
  changes: { value: { from: false, to: true } },
  user_id: 123,
  timestamp: "2024-01-01T12:00:00Z"
}
```

### feature_enabled / feature_disabled
```ruby
{
  feature_name: "new_dashboard",
  context: { user_id: 123, role: "admin" },
  timestamp: "2024-01-01T12:00:00Z"
}
```

### dependency_added / dependency_removed
```ruby
{
  feature_name: "advanced_feature",
  dependency_name: "base_feature",
  timestamp: "2024-01-01T12:00:00Z"
}
```

### variant_set
```ruby
{
  feature_name: "button_color",
  variants: [
    { name: "blue", value: "#0066cc", weight: 50 },
    { name: "green", value: "#00cc66", weight: 30 }
  ],
  timestamp: "2024-01-01T12:00:00Z"
}
```

### variant_selected
```ruby
{
  feature_name: "button_color",
  variant_name: "blue",
  context: { user_id: 123 },
  timestamp: "2024-01-01T12:00:00Z"
}
```

### targeting_added / targeting_removed
```ruby
{
  feature_name: "new_dashboard",
  targeting_type: "user",
  targeting_value: "123",
  timestamp: "2024-01-01T12:00:00Z"
}
```

### version_saved
```ruby
{
  feature_name: "new_dashboard",
  version: 2,
  created_by: 123,
  timestamp: "2024-01-01T12:00:00Z"
}
```

### rollback
```ruby
{
  feature_name: "new_dashboard",
  version: 1,
  timestamp: "2024-01-01T12:00:00Z"
}
```

### exported / imported
```ruby
{
  format: "json",
  feature_count: 10,
  timestamp: "2024-01-01T12:00:00Z"
}
```

### audit_logged
```ruby
{
  feature_name: "new_dashboard",
  action: "set_value",
  user_id: 123,
  changes: { value: { from: false, to: true } },
  timestamp: "2024-01-01T12:00:00Z"
}
```

### usage_tracked
```ruby
{
  feature_name: "new_dashboard",
  operation: "enabled?",
  duration: 0.5, # milliseconds
  success: true,
  timestamp: "2024-01-01T12:00:00Z"
}
```

### deprecated_warning
```ruby
{
  feature_name: "old_feature",
  timestamp: "2024-01-01T12:00:00Z"
}
```

## Integration Examples

### Send to Monitoring Service

```ruby
class MonitoringSubscriber
  def emit(event)
    # Send to Datadog, New Relic, etc.
    StatsD.increment(event[:name], tags: [
      "feature:#{event[:payload][:feature_name]}"
    ])
  end
end

Rails.event.subscribe('magick.feature_flag.changed', MonitoringSubscriber.new)
```

### Track Feature Usage

```ruby
class AnalyticsSubscriber
  def emit(event)
    if event[:name] == 'magick.feature_flag.usage_tracked'
      Analytics.track('feature_flag_checked', {
        feature: event[:payload][:feature_name],
        duration: event[:payload][:duration],
        success: event[:payload][:success]
      })
    end
  end
end

Rails.event.subscribe('magick.feature_flag.usage_tracked', AnalyticsSubscriber.new)
```

### Alert on Deprecated Features

```ruby
class DeprecationAlertSubscriber
  def emit(event)
    if event[:name] == 'magick.feature_flag.deprecated_warning'
      SlackNotifier.notify("Deprecated feature used: #{event[:payload][:feature_name]}")
    end
  end
end

Rails.event.subscribe('magick.feature_flag.deprecated_warning', DeprecationAlertSubscriber.new)
```

### Multiple Subscribers

You can register multiple subscribers for the same event:

```ruby
# Log subscriber
Rails.event.subscribe('magick.feature_flag.changed', Magick::Rails::LogSubscriber.new)

# Monitoring subscriber
Rails.event.subscribe('magick.feature_flag.changed', MonitoringSubscriber.new)

# Analytics subscriber
Rails.event.subscribe('magick.feature_flag.changed', AnalyticsSubscriber.new)
```

## Event Structure

Rails 8.1+ events are hashes with the following structure:

```ruby
{
  name: "magick.feature_flag.changed",           # Event name
  payload: {                                      # Event data
    feature_name: "new_dashboard",
    changes: { value: { from: false, to: true } },
    user_id: 123,
    timestamp: "2024-01-01T12:00:00Z"
  },
  source_location: {                             # Where event was emitted
    filepath: "/app/lib/magick/feature.rb",
    lineno: 253
  },
  tags: { magick: true },                        # Tags (if any)
  context: { request_id: "abc123" }             # Context (if set)
}
```

## Notes

- Events are only emitted when Rails 8.1+ is detected (checks for `Rails.event.notify` availability)
- Events use Rails 8.1+ Structured Event Reporting system
- Event emission is non-blocking and won't affect feature flag performance
- You can register subscribers in initializers, application configuration, or anywhere in your Rails app
- Subscribers must implement the `#emit(event)` method
- Events support tags and context via `Rails.event.tagged` and `Rails.event.set_context`
