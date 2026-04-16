# CLAUDE.md - magick-feature-flags

## Project Overview

Ruby gem (`magick-feature-flags`) v1.4.0 — a performant, memory-efficient feature toggle library for Rails apps. Alternative to Flipper. Author: Andrew Lobanov. License: MIT.

## Quick Reference

```bash
bundle install          # Install dependencies
bundle exec rspec       # Run all tests
bundle exec rubocop     # Run linter
bundle exec rake        # Default task runs specs
```

## Ruby & Dependencies

- **Ruby**: >= 3.2.0 (using 3.3.3 via `.ruby-version`)
- **Runtime deps**: None required (Redis, ActiveRecord, RequestStore all optional)
- **Dev deps**: rspec ~> 3.12, rubocop ~> 1.50, rubocop-rspec ~> 3.8, activerecord >= 6.0 < 9.0, sqlite3 ~> 2.0, rake ~> 13.0
- **Gemspec**: `magick.gemspec`

## Architecture

### Core Design Patterns

1. **Adapter Strategy** — pluggable storage backends (`Magick::Adapters::Base`)
2. **Targeting Strategy** — pluggable targeting rules (`Magick::Targeting::Base`)
3. **Circuit Breaker** — graceful Redis failure handling with fallback
4. **Rails Engine** — Admin UI as mountable engine
5. **DSL** — declarative feature definitions in `config/features.rb`
6. **Event-Driven** — Rails 8.1+ structured events (`magick.feature_flag.*`)

### Adapter Chain (Registry)

Memory → Redis → ActiveRecord (fallback order). Registry orchestrates reads (try memory first) and writes (update all adapters). Redis Pub/Sub for cross-process cache invalidation with 2.0s debounce.

### Key Modules

| Module | Location | Purpose |
|--------|----------|---------|
| `Magick` | `lib/magick.rb` | Main entry point, singleton API |
| `Magick::Feature` | `lib/magick/feature.rb` | Core feature class |
| `Magick::Adapters::*` | `lib/magick/adapters/` | Memory, Redis, ActiveRecord, Registry |
| `Magick::Targeting::*` | `lib/magick/targeting/` | User, Group, Role, Percentage, DateRange, IP, Tag, Custom, Complex |
| `Magick::DSL` | `lib/magick/dsl.rb` | Feature definition DSL |
| `Magick::Config` | `lib/magick/config.rb` | Configuration management |
| `Magick::Rails::*` | `lib/magick/rails/` | Railtie, Events, EventSubscriber |
| `Magick::AdminUI::*` | `lib/magick/admin_ui/` | Engine, helpers, routes |
| `Magick::CircuitBreaker` | `lib/magick/circuit_breaker.rb` | Redis failure handling |
| `Magick::AuditLog` | `lib/magick/audit_log.rb` | Change tracking |
| `Magick::PerformanceMetrics` | `lib/magick/performance_metrics.rb` | Async metrics collection |
| `Magick::Versioning` | `lib/magick/versioning.rb` | Feature state snapshots & rollback |
| `Magick::ExportImport` | `lib/magick/export_import.rb` | Serialization |
| `Magick::FeatureDependency` | `lib/magick/feature_dependency.rb` | Feature prerequisites |
| `Magick::FeatureVariant` | `lib/magick/feature_variant.rb` | A/B testing |
| `Magick::TestingHelpers` | `lib/magick/testing_helpers.rb` | RSpec helpers |

## File Structure

```
lib/
  magick.rb                          # Main module
  magick_feature_flags.rb            # Rails auto-require wrapper
  magick/
    version.rb, feature.rb, errors.rb, config.rb, dsl.rb
    circuit_breaker.rb, audit_log.rb, performance_metrics.rb
    versioning.rb, export_import.rb, feature_dependency.rb
    feature_variant.rb, documentation.rb, testing_helpers.rb
    admin_ui.rb
    adapters/    (base, memory, redis, active_record, registry)
    targeting/   (base, user, group, role, percentage, request_percentage,
                  date_range, ip_address, custom_attribute, complex, tag [if exists])
    rails/       (railtie, events, event_subscriber)
    admin_ui/    (engine, helpers, routes)
app/
  controllers/magick/adminui/  (features_controller, stats_controller)
  views/magick/adminui/        (features: index, show, edit; layouts; stats)
config/
  routes.rb, features.rb.example, magick.rb.example
lib/generators/magick/
  install/     (install_generator + template)
  active_record/ (active_record_generator + migration template)
spec/
  spec_helper.rb
  magick_spec.rb
  magick/
    feature_spec.rb, admin_ui_spec.rb, documentation_spec.rb
    adapters/ (memory_spec, redis_spec, registry_spec, active_record_spec)
```

## Code Conventions

### Style

- **`# frozen_string_literal: true`** at top of every `.rb` file
- RuboCop: target Ruby 3.2, minimal config (`.rubocop.yml`)
- Classes: `CamelCase` | Methods: `snake_case` | Constants: `SCREAMING_SNAKE_CASE`
- Cache instance vars: `@_prefixed` (e.g., `@_targeting_empty`, `@_rails_events_enabled`)
- All shared state protected by `Mutex` (thread-safe)

### Testing

- RSpec with `--format documentation --color`
- `config.disable_monkey_patching!` — use `RSpec.describe`, not `describe`
- `:expect` syntax only (no `should`)
- `Magick.reset!` called `before(:each)` automatically
- Test helpers: `with_feature_enabled`, `with_feature_disabled`, `with_feature_value`
- Adapter tests use `let(:adapter_registry)` pattern

### Error Handling

- **Fail-safe**: `enabled?` returns `false` on any error (never raises in production path)
- Custom errors in `Magick::Errors`
- Circuit breaker for Redis (threshold: 5, timeout: 60s)

## Commit Messages

Format: `[type] Description`

Types:
- `[feature]` — new functionality
- `[update]` — enhancements, version bumps
- `[fix]` — bug fixes
- `[test]` — test additions/improvements
- `[docs]` — documentation
- `[ci]` — CI/CD changes

## Exclusion Targeting

Exclusions always take priority over inclusions. Stored in `@targeting` under `:excluded_*` keys.

### Public API (Feature instance)
- `exclude_user(id)` / `remove_user_exclusion(id)`
- `exclude_tag(name)` / `remove_tag_exclusion(name)`
- `exclude_group(name)` / `remove_group_exclusion(name)`
- `exclude_role(name)` / `remove_role_exclusion(name)`
- `exclude_ip_addresses(ips)` / `remove_ip_exclusion`

### DSL methods
- `exclude_user(feature, id)`, `exclude_tag(feature, name)`, `exclude_group(feature, name)`, `exclude_role(feature, name)`, `exclude_ip_addresses(feature, *ips)`

### Targeting keys
`:excluded_users`, `:excluded_tags`, `:excluded_groups`, `:excluded_roles`, `:excluded_ip_addresses`

### Evaluation order in `check_enabled`
1. Status checks (inactive/deprecated)
2. **Exclusion check** (if excluded → false, always wins)
3. Date range, IP, custom attributes, complex conditions
4. Inclusion targeting (user/group/role/tag/percentage)
5. Value check

## Key Implementation Details

- **Memory adapter**: Hash-based, TTL support (default 3600s), auto-cleanup every 30s, JSON serialization
- **Redis adapter**: DB 1 by default (avoids Rails cache on DB 0), SCAN instead of KEYS, pipelined bulk ops, Pub/Sub for invalidation, async writes optional, JSON serialization
- **ActiveRecord adapter**: Auto-detects PostgreSQL for JSONB, text fallback for MySQL/SQLite
- **Registry**: Debounces local writes (2.0s) to prevent Pub/Sub self-invalidation
- **Performance metrics**: Lock-free Queue, background thread, batch flush (100 metrics or 60s)
- **Feature types**: `:boolean`, `:string`, `:number`
- **Feature statuses**: `:active`, `:inactive`, `:deprecated`
- **Context extraction**: Automatic from objects (`id`, `user_id`, `group`, `role`, `tags`, `ip_address`)
- **Request caching**: Via RequestStore gem (per-request dedup of `enabled?` calls)
- **Preloading**: Bulk loads all features on Rails boot (1-2 queries)

## Admin UI

Rails Engine mounted at `/magick` (configurable). Routes handle feature CRUD, targeting management, enable/disable, and stats. Configure with `Magick::AdminUI.configure` (available_roles, available_tags).

## Working with This Gem

### Adding a New Adapter

1. Create `lib/magick/adapters/my_adapter.rb` inheriting from `Magick::Adapters::Base`
2. Implement required methods: `get`, `set`, `delete`, `exists?`, `all_features`, `get_all_data`, `load_all_features_data`, `set_all_data`
3. Add specs in `spec/magick/adapters/my_adapter_spec.rb`
4. Register in `Magick::Config`

### Adding a New Targeting Strategy

1. Create `lib/magick/targeting/my_strategy.rb` inheriting from `Magick::Targeting::Base`
2. Implement `matches?(context)` method
3. Add specs
4. Wire into `Feature#check_enabled` and DSL

### Version Bumps

Update `lib/magick/version.rb` (single source of truth for `Magick::VERSION`).
