# Magick

A performant and memory-efficient feature toggle gem for Ruby and Rails applications.

## Features

- **Multiple Feature Types**: Boolean, string, and number feature flags
- **Flexible Targeting**: Enable features for specific users, groups, roles, or percentages
- **Dual Backend**: Memory adapter (fast) with Redis fallback (persistent)
- **Rails Integration**: Seamless integration with Rails, including request store caching
- **DSL Support**: Define features in a Ruby DSL file (`config/features.rb`)
- **Thread-Safe**: All operations are thread-safe for concurrent access
- **Performance**: Lightning-fast feature checks with async metrics recording and memory-first caching strategy
- **Advanced Features**: Circuit breaker, audit logging, performance metrics, versioning, and more

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'magick'
```

And then execute:

```bash
$ bundle install
```

Or install it yourself as:

```bash
$ gem install magick
```

## Installation

After adding the gem to your Gemfile and running `bundle install`, generate the configuration file:

```bash
rails generate magick:install
```

This will create `config/initializers/magick.rb` with a basic configuration.

## Configuration

### Basic Configuration

The generator creates `config/initializers/magick.rb` with sensible defaults. You can also create it manually:

```ruby
Magick.configure do
  # Configure Redis (optional)
  # Use database 1 by default to avoid conflicts with Rails cache (which uses DB 0)
  redis url: ENV['REDIS_URL'], db: 1

  # Enable features
  performance_metrics enabled: true
  audit_log enabled: true
  versioning enabled: true
  warn_on_deprecated enabled: true
end
```

### Advanced Configuration

```ruby
Magick.configure do
  # Environment
  environment Rails.env

  # Memory TTL
  memory_ttl 7200 # 2 hours

  # Redis configuration
  # Use separate database (DB 1) to avoid conflicts with Rails cache (DB 0)
  # This ensures feature toggles persist even when Rails cache is cleared
  redis url: ENV['REDIS_URL'], namespace: 'magick:features', db: 1
  # Or include database in URL: redis url: 'redis://localhost:6379/1'

  # Circuit breaker settings
  circuit_breaker threshold: 5, timeout: 60

  # Async updates
  async_updates enabled: true

  # Enable services
  performance_metrics(
    enabled: true,
    redis_tracking: true,  # Auto-enabled if Redis is configured
    batch_size: 100,       # Flush after 100 updates
    flush_interval: 60     # Or flush every 60 seconds
  )
  audit_log enabled: true
  versioning enabled: true
  warn_on_deprecated enabled: true
end
```

## Usage

### Basic Usage

```ruby
# Check if a feature is enabled
if Magick.enabled?(:new_dashboard)
  # Show new dashboard
end

# With context (user, role, etc.)
if Magick.enabled?(:premium_features, user_id: current_user.id, role: current_user.role)
  # Show premium features
end
```

### Registering Features

```ruby
# Register a boolean feature
Magick.register_feature(:new_dashboard,
  type: :boolean,
  default_value: false,
  description: "New dashboard UI"
)

# Register a string feature
Magick.register_feature(:api_version,
  type: :string,
  default_value: "v1",
  description: "API version to use"
)

# Register a number feature
Magick.register_feature(:max_results,
  type: :number,
  default_value: 10,
  description: "Maximum number of results"
)
```

### Feature Targeting

```ruby
feature = Magick[:new_dashboard]

# Enable globally (for everyone, no targeting)
feature.enable

# Disable globally (for everyone, no targeting)
feature.disable

# Enable for specific user
feature.enable_for_user(123)

# Enable for specific group
feature.enable_for_group("beta_testers")

# Enable for specific role
feature.enable_for_role("admin")

# Enable for percentage of users (consistent)
feature.enable_percentage_of_users(25) # 25% of users

# Enable for percentage of requests (random)
feature.enable_percentage_of_requests(50) # 50% of requests

# Enable for date range
feature.enable_for_date_range('2024-01-01', '2024-12-31')

# Enable for IP addresses
feature.enable_for_ip_addresses('192.168.1.0/24', '10.0.0.1')

# Enable for custom attributes
feature.enable_for_custom_attribute(:subscription_tier, ['premium', 'enterprise'])
```

### Checking Feature Enablement with Objects

You can check if a feature is enabled for an object (like a User model) and its fields:

```ruby
# Using enabled_for? with an object
user = User.find(123)
if Magick.enabled_for?(:premium_features, user)
  # Feature is enabled for this user
end

# Or using the feature directly
feature = Magick[:premium_features]
if feature.enabled_for?(user)
  # Feature is enabled for this user
end

# With additional context
if Magick.enabled_for?(:premium_features, user, ip_address: request.remote_ip)
  # Feature is enabled for this user and IP
end

# Works with ActiveRecord objects, hashes, or simple IDs
Magick.enabled_for?(:feature, user)           # ActiveRecord object
Magick.enabled_for?(:feature, { id: 123, role: 'admin' })  # Hash
Magick.enabled_for?(:feature, 123)            # Simple ID
```

The `enabled_for?` method automatically extracts:
- `user_id` from `id` or `user_id` attribute
- `group` from `group` attribute
- `role` from `role` attribute
- `ip_address` from `ip_address` attribute
- All other attributes for custom attribute matching

### Return Values

All enable/disable methods now return `true` to indicate success:

```ruby
# All these methods return true on success
result = feature.enable                    # => true
result = feature.disable                   # => true
result = feature.enable_for_user(123)      # => true
result = feature.enable_for_group('beta')  # => true
result = feature.enable_percentage_of_users(25)  # => true
result = feature.set_value(true)          # => true
```

### DSL Configuration

Create `config/features.rb`:

```ruby
# Boolean features
boolean_feature :new_dashboard,
  default: false,
  name: "New Dashboard",
  description: "New dashboard UI"

boolean_feature :dark_mode,
  default: false,
  name: "Dark Mode",
  description: "Dark mode theme"

# String features
string_feature :api_version, default: "v1", description: "API version"

# Number features
number_feature :max_results, default: 10, description: "Maximum results per page"

# With status
feature :experimental_feature,
  type: :boolean,
  default_value: false,
  status: :deprecated,
  description: "Experimental feature (deprecated)"

# With dependencies (feature will only be enabled if dependencies are enabled)
boolean_feature :advanced_feature,
  default: false,
  description: "Advanced feature requiring base_feature",
  dependencies: [:base_feature]

# Multiple dependencies
boolean_feature :premium_feature,
  default: false,
  description: "Premium feature requiring multiple features",
  dependencies: [:base_feature, :auth_feature]

# Add dependencies after feature definition
add_dependency(:another_feature, :required_feature)
```

### In Controllers

```ruby
class DashboardController < ApplicationController
  def show
    if Magick.enabled?(:new_dashboard, user_id: current_user.id, role: current_user.role)
      render :new_dashboard
    else
      render :old_dashboard
    end
  end
end
```

### Advanced Features

#### Feature Variants (A/B Testing)

```ruby
feature = Magick[:button_color]
feature.set_variants([
  { name: 'blue', value: '#0066cc', weight: 50 },
  { name: 'green', value: '#00cc66', weight: 30 },
  { name: 'red', value: '#cc0000', weight: 20 }
])

variant = feature.get_variant
# Returns 'blue', 'green', or 'red' based on weights
```

#### Feature Dependencies

```ruby
feature = Magick[:advanced_feature]
feature.add_dependency(:base_feature)
# advanced_feature can be enabled independently
# However, base_feature (dependency) cannot be enabled if advanced_feature (main feature) is disabled
# This ensures dependencies are only enabled when their parent features are enabled

# Example:
Magick[:advanced_feature].disable  # => true
Magick[:base_feature].enable        # => false (cannot enable dependency when main feature is disabled)

Magick[:advanced_feature].enable   # => true
Magick[:base_feature].enable        # => true (now can enable dependency)
```

#### Export/Import

```ruby
# Export features
json_data = Magick.export(format: :json)
File.write('features.json', json_data)

# Import features
Magick.import(File.read('features.json'))
```

#### Versioning and Rollback

```ruby
# Save current state as version
Magick.versioning.save_version(:my_feature, created_by: current_user.id)

# Rollback to previous version
Magick.versioning.rollback(:my_feature, version: 2)
```

#### Performance Metrics

```ruby
# Get comprehensive stats for a feature
Magick.feature_stats(:my_feature)
# => {
#   usage_count: 1250,
#   average_duration: 0.032,
#   average_duration_by_operation: {
#     enabled: 0.032,
#     value: 0.0,
#     get_value: 0.0
#   }
# }

# Get just the usage count
Magick.feature_usage_count(:my_feature)
# => 1250

# Get average duration (optionally filtered by operation)
Magick.feature_average_duration(:my_feature)
Magick.feature_average_duration(:my_feature, operation: 'enabled?')

# Get most used features
Magick.most_used_features(limit: 10)
# => {
#   "my_feature" => 1250,
#   "another_feature" => 890,
#   ...
# }

# Direct access to performance metrics (for advanced usage)
Magick.performance_metrics.average_duration(feature_name: :my_feature)
Magick.performance_metrics.usage_count(:my_feature)
Magick.performance_metrics.most_used_features(limit: 10)
```

**Configuration:**

```ruby
Magick.configure do
  performance_metrics(
    enabled: true,
    redis_tracking: true,  # Auto-enabled if Redis is configured
    batch_size: 100,       # Flush after 100 updates
    flush_interval: 60     # Or flush every 60 seconds
  )
end
```

**Performance:** Metrics are recorded asynchronously in a background thread, ensuring zero overhead on feature checks. The `enabled?` method remains lightning-fast even with metrics enabled.

**Note:** When `redis_tracking: true` is set, usage counts are persisted to Redis and aggregated across all processes, giving you total usage statistics. Metrics are automatically flushed in batches to minimize Redis overhead.

#### Audit Logging

```ruby
# View audit log entries
entries = Magick.audit_log.entries(feature_name: :my_feature, limit: 100)
entries.each do |entry|
  puts "#{entry.timestamp}: #{entry.action} by #{entry.user_id}"
end
```

## Architecture

### Adapters

Magick uses a dual-adapter strategy:

1. **Memory Adapter**: Fast, in-memory storage with TTL support
2. **Redis Adapter**: Persistent storage for distributed systems (optional)

The registry automatically falls back from memory to Redis if a feature isn't found in memory. When features are updated:
- Both adapters are updated simultaneously
- Cache invalidation messages are published via Redis Pub/Sub to notify other processes
- Targeting updates trigger immediate cache invalidation to ensure consistency

#### Memory-Only Mode

If Redis is not configured, Magick works in **memory-only mode**:
- ✅ Fast, zero external dependencies
- ✅ Perfect for single-process applications or development
- ⚠️ **No cross-process cache invalidation** - each process has isolated cache
- ⚠️ Changes in one process won't be reflected in other processes

#### Redis Mode (Recommended for Production)

With Redis configured:
- ✅ Cross-process cache invalidation via Redis Pub/Sub
- ✅ Persistent storage across restarts
- ✅ Zero Redis calls on feature checks (only memory lookups)
- ✅ Automatic cache invalidation when features change in any process
- ✅ **Isolated from Rails cache** - Use `db: 1` to store feature toggles in a separate Redis database, ensuring they persist even when Rails cache is cleared

**Important:** By default, Magick uses Redis database 1 to avoid conflicts with Rails cache (which typically uses database 0). This ensures that clearing Rails cache (`Rails.cache.clear`) won't affect your feature toggle states.

### Feature Types

- `:boolean` - True/false flags
- `:string` - String values
- `:number` - Numeric values

### Feature Status

- `:active` - Feature is active and can be enabled
- `:inactive` - Feature is disabled for everyone
- `:deprecated` - Feature is deprecated (can be enabled with `allow_deprecated: true` in context)

## Testing

Use the testing helpers in your RSpec tests:

```ruby
RSpec.describe MyFeature do
  it 'works with feature enabled' do
    with_feature_enabled(:new_feature) do
      # Test code here
    end
  end

  it 'works with feature disabled' do
    with_feature_disabled(:new_feature) do
      # Test code here
    end
  end
end
```

## Development

After checking out the repo, run:

```bash
bundle install
rspec
```

## Contributing

Bug reports and pull requests are welcome on GitHub.

## License

The gem is available as open source under the terms of the [MIT License](LICENSE).
