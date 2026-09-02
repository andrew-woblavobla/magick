# Magick

A performant and memory-efficient feature toggle gem for Ruby and Rails applications.

## Features

- **Multiple Feature Types**: Boolean, string, and number feature flags
- **A/B Testing**: Built-in experiment support with deterministic, weighted variant assignment
- **Flexible Targeting**: Enable features for specific users, groups, roles, tags, or percentages
- **Exclusions**: Exclude specific users, groups, roles, tags, or IPs — exclusions always take priority over inclusions
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

If you want to use ActiveRecord as a persistent storage backend, you **must** generate and run the migration:

```bash
rails generate magick:active_record
rails db:migrate
```

This will create a migration file that creates the `magick_features` table. **The adapter will not auto-create the table** - you must run migrations.

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
  description: "New dashboard UI",
  group: "UI"  # Optional: group features for organization
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

# Enable for specific tag
feature.enable_for_tag("premium")
feature.enable_for_tag("beta")

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

### Global Toggles and Bulk Toggles

`enable` and `disable` are the global switches: they set the feature's value
**and** clear its targeting, so a flag that was on for one specific user is off
for that user too once it has been disabled.

Both are all-or-nothing. Only a boolean feature has an "on", and calling
`enable` on a string or number feature raises without having changed or
persisted anything:

```ruby
Magick[:api_version].enable_for_user(123)

Magick[:api_version].enable
# => Magick::InvalidFeatureValueError: Cannot enable string feature. Use set_value instead.

Magick[:api_version].targeting # => { user: ["123"] } — untouched, in memory and in the backend
```

`Magick.bulk_enable` and `Magick.bulk_disable` apply exactly those semantics to
a list of features. They return a `Magick::BulkResult`, which iterates as the
array of features it was handed and names anything it could not act on:

```ruby
result = Magick.bulk_disable(%i[checkout new_dashboard api_version])
result.complete?       # => true — every feature type has an "off"
result.map(&:name)     # => ["checkout", "new_dashboard", "api_version"]

result = Magick.bulk_enable(%i[checkout api_version])
result.complete?       # => false
result.changed         # => [#<Magick::Feature checkout>]
result.skipped         # => [#<Magick::Feature api_version>]
result.skipped_reasons # => { "api_version" => "cannot enable a string feature; use set_value" }
```

A bulk call still acts on every feature it can; `skipped_reasons` is how you
tell a partial run from a complete one.

### Wire Targeting Payload (control-plane APIs)

For building flag-management endpoints on top of the gem (an internal panel,
a sync job, any JSON API), two primitives implement the wire contract — the
gem ships no routes, your app owns paths and auth:

```ruby
# GET side — full flag payload, string keys. The "targeting" key is ALWAYS
# present ({} = no targeting); list rules are arrays of strings, percentages
# floats. Rails-idiomatic: works with render json: directly.
render json: Magick.features.values          # [{... "targeting" => {"user" => ["3"], "percentage_users" => 50.0}}, ...]

# PATCH side — wholesale, declarative write: the payload IS the new targeting
# state. Keys absent from the payload are removed; {} clears everything.
feature.replace_targeting(payload['targeting'])
```

`replace_targeting` is lenient about input spellings (string or symbol keys,
plural aliases like `users:`, scalars for lists, numeric strings) but strict
about content: unknown keys or invalid values (percentage outside `(0, 100]`,
malformed date ranges, junk IPs) raise `Magick::InvalidTargetingError`
*before anything is applied* — map it to a 422:

```ruby
rescue Magick::InvalidTargetingError => e
  render json: { error: e.message }, status: :unprocessable_entity
```

Each call records one audit entry and one version snapshot
(`replace_targeting`). A/B variants are not part of the targeting payload —
they never appear inside the wire `targeting` object and survive a replace
untouched (manage them via `set_variants`). `enable`/`disable` still clear
all targeting wholesale, so their wire representation is `"targeting": {}`.

### Feature Exclusions

Exclusions let you block specific users, groups, roles, tags, or IP addresses from a feature — even if they match an inclusion rule. **Exclusions always take priority over inclusions.**

```ruby
feature = Magick[:new_dashboard]

# Exclude specific users
feature.exclude_user(456)
feature.exclude_user(789)

# Exclude specific tags
feature.exclude_tag('legacy_tier')
feature.exclude_tag('banned')

# Exclude specific groups
feature.exclude_group('suspended_users')

# Exclude specific roles
feature.exclude_role('guest')

# Exclude IP addresses (supports CIDR notation)
feature.exclude_ip_addresses(['10.0.0.0/8', '192.168.1.100'])

# Remove exclusions
feature.remove_user_exclusion(456)
feature.remove_tag_exclusion('legacy_tier')
feature.remove_group_exclusion('suspended_users')
feature.remove_role_exclusion('guest')
feature.remove_ip_exclusion  # Removes all IP exclusions
```

**Exclusions win over inclusions:**

```ruby
feature = Magick[:premium_features]
feature.enable  # Enabled globally for everyone

feature.exclude_user(123)
Magick.enabled?(:premium_features, user_id: 123)  # => false (excluded)
Magick.enabled?(:premium_features, user_id: 456)  # => true  (not excluded)

# Even percentage targeting is overridden
feature.enable_percentage_of_users(100)  # 100% of users
feature.exclude_user(123)
Magick.enabled?(:premium_features, user_id: 123)  # => false (still excluded)
```

**Exclusions in DSL (`config/features.rb`):**

```ruby
boolean_feature :new_dashboard, default: true

# Exclude problematic users
exclude_user :new_dashboard, 'user_123'
exclude_user :new_dashboard, 'user_456'

# Exclude legacy tiers
exclude_tag :new_dashboard, 'legacy_tier'

# Exclude groups
exclude_group :new_dashboard, 'banned_users'

# Exclude roles
exclude_role :new_dashboard, 'suspended'

# Exclude IPs
exclude_ip_addresses :new_dashboard, '10.0.0.0/8'
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

# Tag targeting - tags are automatically extracted from user objects
user = User.find(123)  # User has tags association
feature.enable_for_tag('premium')
Magick.enabled_for?(:feature, user)  # Checks user.tags automatically

# Or explicitly pass tags
Magick.enabled?(:feature, tags: user.tags.map(&:id))
Magick.enabled?(:feature, tags: ['premium', 'beta'])

# Tags are extracted from:
# - user.tags (ActiveRecord association)
# - user.tag_ids (array of IDs)
# - user.tag_names (array of names)
# - hash[:tags], hash[:tag_ids], hash[:tag_names]
```

The `enabled_for?` method automatically extracts:
- `user_id` from `id` or `user_id` attribute
- `group` from `group` attribute
- `role` from `role` attribute
- `tags` from `tags` association, `tag_ids`, or `tag_names` methods/attributes
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
result = feature.enable_for_role('admin')  # => true
result = feature.enable_for_tag('premium') # => true
result = feature.enable_percentage_of_users(25)  # => true
result = feature.set_value(true)          # => true

# Exclusion methods also return true
result = feature.exclude_user(456)         # => true
result = feature.exclude_tag('banned')     # => true
result = feature.exclude_group('blocked')  # => true
result = feature.exclude_role('guest')     # => true
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

# A/B test experiment
experiment :checkout_button,
  name: "Checkout Button",
  description: "Button color experiment",
  variants: [
    { name: 'control', value: '#0066cc', weight: 50 },
    { name: 'green', value: '#00cc66', weight: 30 },
    { name: 'red', value: '#cc0000', weight: 20 }
  ]

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

# Exclusions - block specific users/groups/roles/tags
exclude_user :new_dashboard, 'user_123'
exclude_tag :new_dashboard, 'legacy_tier'
exclude_group :new_dashboard, 'banned_users'
exclude_role :new_dashboard, 'suspended'
exclude_ip_addresses :new_dashboard, '10.0.0.0/8'
```

**Loading a DSL file yourself**

The Rails railtie loads `config/features.rb` for you. If you load one by hand,
use `Magick::ConfigDSL.load_from_file`:

```ruby
Magick.definition_mode { Magick::ConfigDSL.load_from_file(Rails.root.join('config/features.rb')) }
```

`load_from_file` **evaluates the file as Ruby**. Never hand it a path derived
from HTTP params, ENV, or any other untrusted source — that is remote code
execution. As a backstop, the path is resolved with `File.realpath` and must
live inside the project root: `Rails.root` under Rails, otherwise the directory
holding the `Gemfile`. The check is separator-aware (`/srv/app-evil` is not
inside `/srv/app`) and never consults the process working directory, so
starting the app from `/` or chdir-ing later cannot widen it. Outside Rails and
Bundler, set the root explicitly:

```ruby
Magick::ConfigDSL.project_root = '/srv/app'
```

**`MAGICK_ALLOW_CONFIG_EVAL=1` is dangerous.** It disables the containment
check entirely, so any caller that can influence the path gets arbitrary code
execution in your process. Set it only for a trusted file you deliberately keep
outside the project tree, and never on a host where the path can come from a
request.

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

### Per-Request Caching

Add the optional [`request_store`](https://github.com/steveklabnik/request_store)
gem and repeated checks of the same feature with the same context are evaluated
once per request and reused:

```ruby
# Gemfile
gem 'request_store'
```

```ruby
# Evaluated once; the second and third calls reuse the answer.
Magick.enabled?(:new_dashboard, user_id: current_user.id)
Magick.enabled?(:new_dashboard, user_id: current_user.id)
Magick.disabled?(:new_dashboard, user_id: current_user.id)
```

This matters most for `enable_percentage_of_requests`, which rolls a die on
every check. Cached, the whole request gets one answer, so a page cannot render
half of a rollout. The next request rolls again.

The cache is keyed by feature name and context, lives in `RequestStore` and is
cleared with it at the end of each request. It is only consulted inside a
request — in a console, a rake task or at boot, checks are evaluated live,
which is also what happens when `request_store` is not installed. If you change
a feature mid-request and later call sites in that same request must see the
new state, drop the memo:

```ruby
Magick::RequestStoreIntegration.clear!
```

Rails installs this for you. Elsewhere (a Sidekiq-only process, for example)
wire it up yourself — `request_store` ships middleware for both Rack and
Sidekiq:

```ruby
require 'magick/request_store_integration'
Magick::RequestStoreIntegration.install!
```

### Advanced Features

#### A/B Testing (Experiments)

Magick has built-in support for A/B testing with deterministic variant assignment. The same user always gets the same variant (based on MD5 hashing), ensuring consistent experiences.

**Quick setup with DSL (`config/features.rb`):**

```ruby
experiment :checkout_button,
  name: "Checkout Button Color",
  description: "Test which button color converts better",
  variants: [
    { name: 'control', value: '#0066cc', weight: 50 },
    { name: 'green',   value: '#00cc66', weight: 30 },
    { name: 'red',     value: '#cc0000', weight: 20 }
  ]
```

**Or set up programmatically:**

```ruby
feature = Magick[:checkout_button]
feature.set_variants([
  { name: 'control', value: '#0066cc', weight: 50 },
  { name: 'green',   value: '#00cc66', weight: 30 },
  { name: 'red',     value: '#cc0000', weight: 20 }
])
```

**Usage in your application:**

```ruby
# Get the variant name for a user (deterministic — same user always gets same variant)
variant = Magick.variant(:checkout_button, user_id: current_user.id)
# => "control", "green", or "red"

# Get the variant value directly
color = Magick.variant_value(:checkout_button, user_id: current_user.id)
# => "#0066cc", "#00cc66", or "#cc0000"

# Works with user objects too
variant = Magick.variant(:checkout_button, user: current_user)

# Use in views/controllers
class CheckoutController < ApplicationController
  def show
    @button_color = Magick.variant_value(:checkout_button, user: current_user)
    # Same user always sees the same color
  end
end
```

**Experiments without a user (anonymous visitors):**

For flows where there's no authenticated user yet (e.g., registration, landing pages), use any stable identifier as `user_id` — a session ID or a tracking cookie:

```ruby
class RegistrationController < ApplicationController
  def new
    cookies[:visitor_id] ||= SecureRandom.uuid
    @variant = Magick.variant(:registration_flow, user_id: cookies[:visitor_id])
  end
end
```

The hashing just needs a consistent string. As long as the same visitor sends the same identifier, they get the same variant every time.

**Safe to call on non-existent experiments:**

```ruby
Magick.variant(:nonexistent, user_id: 123)  # => nil
Magick.variant_value(:nonexistent, user_id: 123)  # => nil
```

**Important — changing weights may shift users:**

You can change variant weights at any time via the Admin UI or code, and changes take effect immediately across all adapters. However, changing weights alters the bucket boundaries, which means some users may be reassigned to a different variant after the update. Magick does not persist individual user-to-variant assignments — assignment is computed on the fly from the hash. If your experiment requires that users never shift variants mid-experiment, you should persist the assignment externally (e.g., store `user_id → variant` in a database table on first exposure).

**How it works:**
- Variants are assigned using a deterministic MD5 hash of `feature_name + user_id`
- The same user always gets the same variant across sessions and requests
- Weights control the distribution (e.g., 50/30/20 means ~50% control, ~30% green, ~20% red)
- If no `user_id` is provided, falls back to random assignment (useful for anonymous users)
- Experiments are boolean features with variants — they work with all targeting and exclusion rules
- Manage variants through the Admin UI with visual weight distribution

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

The payload carries a feature's whole state — value, status, targeting,
exclusions, A/B variants and dependencies — so an import reproduces the
feature the export was taken from, variant assignment included. Because it is
the whole state, importing a feature whose payload carries no variants also
clears any the target store had for that name.

#### Versioning and Rollback

Every state-changing operation (value, status, group, targeting, exclusions,
variants, dependencies, delete) automatically records a version snapshot and
an audit entry — one per logical operation, under its real action name
(`enable`, `exclude_user`, `set_status`, …). Nested internals never
double-record.

```ruby
# History accumulates automatically:
Magick[:my_feature].enable            # => version 1 (action: "enable")
Magick[:my_feature].enable_for_user(42) # => version 2 (action: "enable_for_user")

# Inspect history (hot window: last 50 versions by default)
Magick.versioning.get_versions(:my_feature)

# Include the unlimited ActiveRecord archive (when AR adapter is configured)
Magick.versioning.get_versions(:my_feature, all: true)

# Rollback fully restores a snapshot: value (including false/empty), status,
# group, and the entire targeting hash — and records the rollback itself as a
# new version, so history only ever rolls forward.
Magick.versioning.rollback(:my_feature, 2)

# Manual snapshots still work (action: "manual")
Magick.versioning.save_version(:my_feature, created_by: current_user.id)
```

**Retention is tiered:** memory/Redis keep the last `max_versions` snapshots
(default 50) for fast access; the ActiveRecord adapter keeps an unlimited
archive that also survives feature deletion.

```ruby
Magick.configure do
  versioning enabled: true, max_versions: 50
end
```

**Version numbers come from the shared store**, not from any one process. Each
snapshot is stored under its own `version_<n>` key inside the reserved
`__magick_versions:<name>` namespace, and the number is allocated by an atomic
counter next to it — a row-locked `UPDATE` on the ActiveRecord row when that
adapter is configured, otherwise Redis `HSETNX` + `HINCRBY`. Every append
re-reads the current history rather than trusting a window cached at boot.

That is what makes history correct across containers: two processes saving at
the same time interleave into one list, neither loses a snapshot, and
`rollback(name, 2)` restores the same state whichever process serves the
request. Only with no shared backend at all (memory-only, single process) is
the counter process-local.

**Custom adapters:** an adapter used with versioning should implement
`#next_sequence(feature_name, key, floor:)` and `#delete_key(feature_name, key)`
in addition to the usual read/write methods. `Magick::Adapters::Base` ships a
read-modify-write `#next_sequence` that is correct for a store only one process
can reach; an adapter backed by a store **shared between processes** must
override it with something genuinely atomic, or two processes will be handed the
same version number. Without `#delete_key`, the hot window is never pruned.

**Attribution:** wrap changes in `Magick.with_actor` to stamp audit entries
(`user_id`) and versions (`created_by`):

```ruby
Magick.with_actor(current_user.id) do
  Magick[:my_feature].enable_for_user(42)
end
```

**Boot replay is not recorded:** the Rails railtie loads `config/features.rb`
inside `Magick.definition_mode`, so re-applying declarative definitions on
every process boot does not flood history. Non-Rails apps should wrap their
own definition file load the same way:

```ruby
Magick.definition_mode { load 'config/features.rb' }
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

**Without Redis** the counts stay in memory and are reported in full: a flush
only drains pending updates once the write has actually landed, so a
Redis-less deployment — or a Redis that is temporarily unreachable — never
loses counts. Durations are kept as a rolling window of the most recent 1,000
samples per process, so averages track recent behaviour rather than the first
samples after boot. Stats that need to enumerate the keyspace use `SCAN`, not
`KEYS`.

#### Audit Logging

Every mutation is logged under its real action name (`enable`, `disable`,
`set_value`, `enable_for_user`, `exclude_role`, `set_status`, `set_group`,
`delete`, `rollback`, …). One logical operation produces exactly one entry:
`enable` no longer surfaces as a bare `set_value`.

```ruby
# View audit log entries — newest last, merged across every process
entries = Magick.audit_log.entries(feature_name: :my_feature, limit: 100)
entries.each do |entry|
  puts "#{entry.id} #{entry.timestamp}: #{entry.action} by #{entry.user_id}"
end
```

**Durability and retention.** Entries are written to every configured adapter
that outlives the process — Redis and/or ActiveRecord — so history survives a
restart and every container can answer "who changed this flag" about a change
made anywhere else. `entries` merges that shared history with the entries this
process wrote itself.

Retention is tiered, like versioning:

| Tier | Where | Kept | Survives restart |
| --- | --- | --- | --- |
| Ring | This process's memory | last `max_entries` (default 10,000) across all features | no |
| Durable store | Redis and/or ActiveRecord | last `retention` (default 200) **per feature** | yes |

The durable store lives under a reserved `__magick_audit:<feature>` pseudo-feature
namespace, so audit history never shows up in the feature list, is not dragged
along by feature reads, and outlives the feature it describes — a deleted flag
keeps the record of who deleted it. Entries carry a unique, chronologically
sortable `id`, which is what de-duplicates them when the same entry is read back
from more than one adapter.

Writes are best-effort and happen outside the lock that guards the ring: a slow
or unavailable backend never fails a feature mutation and never serializes
mutations behind the audit log.

Unlike version numbers, an audit append is a read-merge-write of the feature's
capped list rather than an atomic allocation, so two containers writing for the
same feature in the same instant can drop one entry from the shared list. Each
write merges this process's recent entries back in, so a dropped entry is
restored by that process's next write; entry ids make the merge exact.

**A memory-only deployment has nothing that outlives the process**, so it keeps
only the ring — `Magick.audit_log.durable?` returns `false` there. Configure
Redis or the ActiveRecord adapter to get durable audit history.

```ruby
Magick.configure do
  # Defaults
  audit_log enabled: true, retention: 200, max_entries: 10_000

  # Ship entries to your own sink as well (called with each entry)
  # audit_log adapter: MyAuditSink.new

  # Your sink is the system of record: keep the ring, write nothing to
  # Redis/ActiveRecord
  # audit_log adapter: MyAuditSink.new, persist: false

  # Opt out entirely — Magick.audit_log is nil and nothing is recorded
  # audit_log enabled: false
end
```

A host-supplied adapter only has to respond to `append(entry)`; it is called
outside the ring lock, and an exception it raises is logged rather than
propagated into the feature mutation.

In the Admin UI, configure a `current_actor` hook so every change made
through the UI is attributed:

```ruby
Magick::AdminUI.configure do |config|
  config.current_actor = ->(controller) { controller.session[:admin_id] }
end
```

## Architecture

### Adapters

Magick uses a dual-adapter strategy:

1. **Memory Adapter**: Fast, in-memory storage with TTL support and JSON serialization
2. **Redis Adapter**: Persistent storage for distributed systems (optional), uses SCAN instead of KEYS and pipelined bulk operations

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

1. **Generate and run the migration** (required):
   ```bash
   rails generate magick:active_record
   rails db:migrate
   ```

   **With UUID primary keys:**
   ```bash
   rails generate magick:active_record --uuid
   rails db:migrate
   ```

   **Important:** The adapter will **not** auto-create the table. You must run migrations before using the ActiveRecord adapter. If the table doesn't exist, the adapter will raise a clear error with instructions.

2. Configure in `config/initializers/magick.rb`:
   ```ruby
   Magick.configure do
     active_record # Uses default MagickFeature model
     # Or specify a custom model:
     # active_record model_class: YourCustomModel
   end
   ```

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

#### When a Backend Write Fails

Writes go to memory first and memory is never rolled back, so a Redis or
ActiveRecord write that fails leaves that one process serving a value the rest
of the fleet does not have. The write itself stays contained — a broken backend
never raises into your code — but the divergence is always reported:

- **Logged at `error` severity in every environment** (not just development),
  through `Rails.logger` when there is one and `$stderr` otherwise. Feature
  names and driver messages are sanitized with `Magick::LogSafe`, so nothing
  coming off the wire can forge a log line.
- **Emitted as `magick.feature_flag.adapter_write_failed`** on the structured
  event channel, with `backend`, `operation`, `feature_name` and the error (or
  `reason: "circuit breaker open"` when the write was dropped without being
  attempted). Subscribe to it to alert on divergence — see
  [RAILS8_EVENTS.md](RAILS8_EVENTS.md).

```
Magick: redis set failed for 'new_checkout': Magick::AdapterError: Failed to set in Redis: Connection refused
```

### Admin UI

Magick includes a web-based Admin UI for managing feature flags. It's a Rails Engine that provides a user-friendly interface for viewing, enabling, disabling, and configuring features.

**Setup:**

1. Configure roles and tags (optional) for targeting management in `config/initializers/magick.rb`:

```ruby
Rails.application.config.after_initialize do
  Magick::AdminUI.configure do |config|
    config.available_roles = ['admin', 'user', 'manager', 'guest']
    # Tags can be configured as an array or lambda (for dynamic loading)
    config.available_tags = -> { Tag.all }  # Lambda loads tags dynamically
    # Or as a static array:
    # config.available_tags = ['premium', 'beta', 'vip']
  end
end
```

2. Mount the engine in `config/routes.rb`:

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
  - **Tag Targeting**: Select tags from a dynamically loaded list (checkboxes)
  - **User Targeting**: Enter user IDs (comma-separated)
  - **Exclusions**: Exclude users, roles, and tags from a feature (exclusions override inclusions)
  - **Visual Display**: See all active targeting rules with badges
- **Edit Features**: Update feature values (boolean, string, number) directly from the UI
- **A/B Test Management**: Create and manage experiment variants with visual weight distribution
- **Statistics**: View performance metrics and usage statistics for each feature
- **Feature Grouping**: Organize features into groups for easier management and filtering
- **Filtering**: Filter features by group, name, or description

**Feature Grouping:**

Features can be organized into groups for easier management and filtering:

1. **Setting Groups**:
   - Set a group when registering a feature in code:
     ```ruby
     Magick.register_feature(:new_payment_flow,
       type: :boolean,
       default_value: false,
       group: 'Payment',
       description: "New payment processing flow"
     )
     ```
   - Or set/update groups via the Admin UI when editing a feature

2. **Filtering by Group**:
   - Use the group dropdown in the Admin UI to filter features by group
   - Combine group filtering with search to find specific features quickly

3. **Benefits**:
   - Organize features by functional area (e.g., "Authentication", "Payment", "UI")
   - Quickly find related features
   - Better organization for large feature flag sets

**Targeting Management:**

The Admin UI provides a comprehensive targeting interface:

1. **Role Targeting**:
   - Configure available roles via `Magick::AdminUI.configure`
   - Select multiple roles using checkboxes
   - Roles are automatically added/removed when checkboxes are toggled

2. **Tag Targeting**:
   - Configure available tags via `Magick::AdminUI.configure` (supports lambda for dynamic loading)
   - Tags are loaded dynamically each time the page loads (if using lambda)
   - Select multiple tags using checkboxes
   - Tags are automatically added/removed when checkboxes are toggled
   - Tags can be ActiveRecord objects (IDs are stored) or simple strings

3. **User Targeting**:
   - Enter user IDs as comma-separated values (e.g., `123, 456, 789`)
   - Add or remove users dynamically
   - Clear all user targeting by leaving the field empty

4. **Exclusion Targeting**:
   - Exclude specific users (comma-separated IDs), roles, and tags
   - Exclusions always take priority over inclusions
   - Managed through the same targeting form

5. **Visual Feedback**:
   - All targeting rules are displayed as badges in the feature details view
   - Easy to see which roles/tags/users have access to each feature

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
- `PUT /magick/features/:id/update_variants` - Update A/B test variants
- `GET /magick/stats/:id` - View feature statistics

**Security:**

Gating at the router is the more robust of the two options below, and the one
to reach for in production: it covers everything the engine mounts — including
routes added by a later version of this gem — and it stops unauthenticated
requests before they reach the gem at all.

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

If your auth layer does not fit a router-level block, the Admin UI also
includes a built-in authentication hook via `require_role`. It runs on every
route the engine exposes — feature routes and the stats route alike:

```ruby
# config/initializers/magick.rb
Rails.application.config.after_initialize do
  Magick::AdminUI.configure do |config|
    # Option 1: Lambda-based authentication
    config.require_role = ->(controller) {
      # Return true to allow, false to deny (returns 403 Forbidden)
      controller.current_user&.admin?
    }

    # Option 2: Check for a specific role
    config.require_role = ->(controller) {
      controller.current_user&.role == 'admin'
    }
  end
end
```

`require_role` must be a callable (a lambda or proc taking the controller) or
`nil`. A bare role name is **rejected** — `config.require_role = :admin` raises
`Magick::ConfigurationError` at configuration time rather than being accepted
and then ignored on every request:

```ruby
config.require_role = :admin    # => Magick::ConfigurationError
config.require_role = 'admin'   # => Magick::ConfigurationError
```

**Note:** The Admin UI is optional and only loaded when explicitly enabled in configuration. It requires Rails to be available.

### Feature Types

- `:boolean` - True/false flags
- `:string` - String values
- `:number` - Numeric values

### Feature Status

- `:active` - Feature is active and can be enabled
- `:inactive` - Feature is disabled for everyone
- `:deprecated` - Feature is deprecated (can be enabled with `allow_deprecated: true` in context)

## Graceful Shutdown

Magick starts a background Redis Pub/Sub subscriber thread for cross-process
cache invalidation and an asynchronous metrics processor. Both must be
stopped before the host process exits or Puma's graceful-stop will block on
the still-running `Redis#subscribe` call.

The Railtie registers an `at_exit` hook that calls `Magick.shutdown!`
automatically, so most Rails apps don't need to do anything. In long-running
non-Rails processes (rake tasks, CLI tools) call it explicitly:

```ruby
Magick.shutdown!          # default 5 second join timeout
Magick.shutdown!(timeout: 1)  # more aggressive
```

Fork-based deployments (Puma workers with `preload_app!`, Unicorn) are handled
automatically. A Rack middleware (`Magick::Rails::SubscriberMiddleware`) calls
`ensure_subscriber!` on each request — a pid-guarded no-op once the subscriber
is running — so a worker that inherited a dead parent thread starts its own
subscriber on its first request. This matters because in production
`config.to_prepare` runs **once at boot** (before workers fork), not per
request, so it cannot revive the subscriber inside forked workers on its own.
No action required from the host app.

## Admin UI Security

The Admin UI is CSRF-protected out of the box (`protect_from_forgery with:
:exception`) and 404s on unknown feature IDs instead of auto-creating
features from user-controlled `params[:id]`.

Authentication is **opt-in** — if `Magick::AdminUI.config.require_role` is
left `nil` the UI is reachable by anyone who can hit its routes. Always put it
behind your app's auth, preferably at the router, which gates every route the
engine mounts, present and future:

```ruby
# config/routes.rb — the more robust option
authenticate :admin_user do
  mount Magick::AdminUI::Engine, at: '/magick'
end
```

The built-in hook is the alternative when a router-level block does not fit.
It gates every Admin UI route, and it is fail-closed: it must be a callable or
`nil`, and a value that is neither (a role name, say) raises
`Magick::ConfigurationError` when assigned rather than quietly leaving the
panel open.

```ruby
Magick::AdminUI.configure do |c|
  c.require_role = ->(controller) { controller.current_user&.admin? }
end
```

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
bundle exec rspec       # full suite; needs no external services
bundle exec rubocop     # linter
```

### Redis integration specs

The specs that exercise the Redis adapter, Pub/Sub cache invalidation, and the
circuit breaker need a real Redis. They are opt-in, so a contributor without
Redis is never blocked — `bundle exec rspec` skips them and stays green.

```bash
redis-server &                        # or: docker run -p 6379:6379 redis:7
bundle exec rake spec:redis           # defaults to REDIS_URL=redis://localhost:6379/1
REDIS_URL=redis://elsewhere:6379/1 bundle exec rake spec:redis
```

They run in their own RSpec process on purpose. Requiring the `redis` gem
defines `::Redis`, and Magick's adapter auto-detection keys off
`defined?(Redis)` — sharing a process would silently point the rest of the suite
at a real Redis and leak state between examples.

`rake spec:redis` sets `MAGICK_REDIS_SPECS=1`, which makes the gate strict: an
unreachable Redis aborts the run rather than quietly skipping. CI relies on this,
plus a check that the executed example count is non-zero, so the build cannot go
green on specs that never ran. **Note that `rake spec:redis` calls `FLUSHDB` on
the database in `REDIS_URL`** — point it at a scratch database, not one holding
data you care about.

## Contributing

Bug reports and pull requests are welcome on GitHub.

## License

The gem is available as open source under the terms of the [MIT License](LICENSE).
