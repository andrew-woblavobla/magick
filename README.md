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

## Setup

After adding the gem to your Gemfile and running `bundle install`, generate the configuration file:

```bash
rails generate magick:install
```

This will create `config/initializers/magick.rb` with a basic configuration.

### ActiveRecord Adapter (Optional)

If you want to use ActiveRecord as a persistent storage backend, generate the migration:

```bash
rails generate magick:active_record
```

This will create a migration file that creates the `magick_features` table. Then run:

```bash
rails db:migrate
```

**Note:** The ActiveRecord adapter is optional and only needed if you want database-backed feature flags. The gem works perfectly fine with just the memory adapter or Redis adapter.

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

  # Enable Admin UI (optional)
  admin_ui enabled: true
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

#### ActiveRecord Adapter (Optional)

The ActiveRecord adapter provides database-backed persistent storage for feature flags. It's useful when you want to:
- Store feature flags in your application database
- Use ActiveRecord models for feature management
- Have a fallback storage layer
- Work with PostgreSQL, MySQL, SQLite, or any ActiveRecord-supported database

**Setup:**

1. Generate the migration:
   ```bash
   rails generate magick:active_record
   rails db:migrate
   ```

   **With UUID primary keys:**
   ```bash
   rails generate magick:active_record --uuid
   ```

2. Configure in `config/initializers/magick.rb`:
   ```ruby
   Magick.configure do
     active_record # Uses default MagickFeature model
     # Or specify a custom model:
     # active_record model_class: YourCustomModel
   end
   ```

The adapter automatically creates the `magick_features` table if it doesn't exist, but using the generator is recommended for production applications.

**PostgreSQL Support:**

The generator automatically detects PostgreSQL and uses `jsonb` for the `data` column, providing:
- Better performance with native JSON queries
- Native JSON indexing and querying capabilities
- Type-safe JSON storage

For other databases (MySQL, SQLite, etc.), it uses `text` with serialized JSON.

**UUID Primary Keys:**

When using the `--uuid` flag:
- Creates table with `id: :uuid` instead of integer primary key
- Enables `pgcrypto` extension for PostgreSQL (required for UUID generation)
- Works with other databases using their native UUID support

**Note:** The ActiveRecord adapter works as a fallback in the adapter chain: Memory → Redis → ActiveRecord. It's automatically included if ActiveRecord is available and configured.

**Adapter Chain:**

The adapter registry uses a fallback strategy:
1. **Memory Adapter** (first) - Fast, in-memory lookups
2. **Redis Adapter** (second) - Persistent, distributed storage
3. **ActiveRecord Adapter** (third) - Database-backed fallback

When a feature is requested:
- First checks memory cache (fastest)
- Falls back to Redis if not in memory
- Falls back to ActiveRecord if Redis is unavailable or returns nil
- Updates all adapters when features are modified

This ensures maximum performance while maintaining persistence and reliability.

### Admin UI

Magick includes a web-based Admin UI for managing feature flags. It's a Rails Engine that provides a user-friendly interface for viewing, enabling, disabling, and configuring features.

**Setup:**

1. Enable Admin UI in `config/initializers/magick.rb`:

```ruby
Magick.configure do
  admin_ui enabled: true
end
```

2. Configure roles (optional) for targeting management:

```ruby
Magick::AdminUI.configure do |config|
  config.available_roles = ['admin', 'user', 'manager', 'guest']
end
```

3. Mount the engine in `config/routes.rb`:

```ruby
Rails.application.routes.draw do
  # ... your other routes ...

  # With authentication (recommended for production)
  authenticate :admin_user do
    mount Magick::AdminUI::Engine, at: '/magick'
  end

  # Or without authentication (development only)
  # mount Magick::AdminUI::Engine, at: '/magick'
end
```

**Access:**

Once mounted, visit `/magick` in your browser to access the Admin UI.

**Features:**

- **Feature List**: View all registered features with their current status, type, and description
- **Feature Details**: View detailed information about each feature including:
  - Current value/status
  - Targeting rules (users, groups, roles, percentages, etc.)
  - Performance statistics (usage count, average duration)
  - Feature metadata (type, default value, dependencies)
- **Enable/Disable**: Quickly enable or disable features globally
- **Targeting Management**: Configure targeting rules through a user-friendly interface:
  - **Role Targeting**: Select roles from a configured list (checkboxes)
  - **User Targeting**: Enter user IDs (comma-separated)
  - **Visual Display**: See all active targeting rules with badges
- **Edit Features**: Update feature values (boolean, string, number) directly from the UI
- **Statistics**: View performance metrics and usage statistics for each feature

**Targeting Management:**

The Admin UI provides a comprehensive targeting interface:

1. **Role Targeting**:
   - Configure available roles via `Magick::AdminUI.configure`
   - Select multiple roles using checkboxes
   - Roles are automatically added/removed when checkboxes are toggled

2. **User Targeting**:
   - Enter user IDs as comma-separated values (e.g., `123, 456, 789`)
   - Add or remove users dynamically
   - Clear all user targeting by leaving the field empty

3. **Visual Feedback**:
   - All targeting rules are displayed as badges in the feature details view
   - Easy to see which roles/users have access to each feature

**Routes:**

The Admin UI provides the following routes:

- `GET /magick` - Feature list (index)
- `GET /magick/features/:id` - Feature details
- `GET /magick/features/:id/edit` - Edit feature
- `PUT /magick/features/:id` - Update feature value
- `PUT /magick/features/:id/enable` - Enable feature globally
- `PUT /magick/features/:id/disable` - Disable feature globally
- `PUT /magick/features/:id/enable_for_user` - Enable feature for specific user
- `PUT /magick/features/:id/enable_for_role` - Enable feature for specific role
- `PUT /magick/features/:id/disable_for_role` - Disable feature for specific role
- `PUT /magick/features/:id/update_targeting` - Update targeting rules (roles and users)
- `GET /magick/stats/:id` - View feature statistics

**Security:**

The Admin UI is a basic Rails Engine without built-in authentication. **You should add authentication/authorization** before mounting it in production. For example:

```ruby
# config/routes.rb
Rails.application.routes.draw do
  # Using Devise
  authenticate :admin_user do
    mount Magick::AdminUI::Engine, at: '/magick'
  end

  # Or using session-based authentication
  constraints(->(request) { request.session[:user_id].present? && request.session[:admin] }) do
    mount Magick::AdminUI::Engine, at: '/magick'
  end
end
```

Or use a before_action in your ApplicationController if you mount it at the application level.

**Note:** The Admin UI is optional and only loaded when explicitly enabled in configuration. It requires Rails to be available.

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
