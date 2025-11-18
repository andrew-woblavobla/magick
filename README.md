# Magick

A performant and memory-efficient feature toggle gem for Ruby and Rails applications.

## Features

- **Multiple Feature Types**: Boolean, string, and number feature flags
- **Flexible Targeting**: Enable features for specific users, groups, roles, or percentages
- **Dual Backend**: Memory adapter (fast) with Redis fallback (persistent)
- **Rails Integration**: Seamless integration with Rails, including request store caching
- **DSL Support**: Define features in a Ruby DSL file (`config/features.rb`)
- **Thread-Safe**: All operations are thread-safe for concurrent access
- **Performance**: Optimized for speed with memory-first caching strategy
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
  redis url: ENV['REDIS_URL']

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
  redis url: ENV['REDIS_URL'], namespace: 'magick:features'

  # Circuit breaker settings
  circuit_breaker threshold: 5, timeout: 60

  # Async updates
  async_updates enabled: true

  # Enable services
  performance_metrics enabled: true
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

### DSL Configuration

Create `config/features.rb`:

```ruby
# Boolean features
boolean_feature :new_dashboard, default: false, description: "New dashboard UI"
boolean_feature :dark_mode, default: false, description: "Dark mode theme"

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
# advanced_feature will only be enabled if base_feature is also enabled
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
# Get average duration for feature checks
avg_duration = Magick.performance_metrics.average_duration(feature_name: :my_feature)

# Get most used features
most_used = Magick.performance_metrics.most_used_features(limit: 10)

# Get usage count
count = Magick.performance_metrics.usage_count(:my_feature)
```

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
2. **Redis Adapter**: Persistent storage for distributed systems

The registry automatically falls back from memory to Redis if a feature isn't found in memory. When features are updated, both adapters are updated simultaneously.

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
