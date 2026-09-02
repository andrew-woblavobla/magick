# frozen_string_literal: true

module Magick
  # Per-request memoisation of `Magick.enabled?`.
  #
  # Without it every call site re-evaluates the flag. That is merely wasteful
  # for a deterministic flag, but wrong for a percentage-of-requests rollout:
  # `rand` is re-rolled on every check, so two call sites rendering the same
  # page can disagree about whether the feature is on.
  #
  # Installed by prepending onto Magick's singleton class. `enabled?` is defined
  # directly on that singleton class, so it precedes any included or extended
  # module in the lookup chain — only a prepend can wrap it.
  #
  # The Rails railtie installs this at boot. Outside Rails — a Sidekiq-only
  # process, say — require this file and call `install!` yourself; the
  # `request_store` gem ships middleware for Rack and for Sidekiq.
  module RequestStoreIntegration
    # Key the memo hash lives under inside RequestStore.
    STORE_KEY = :magick_features

    class << self
      # Idempotent. Returns true when it installed, false when already there.
      def install!(target = Magick)
        return false if installed?(target)

        target.singleton_class.prepend(self)
        true
      end

      def installed?(target = Magick)
        target.singleton_class.ancestors.include?(self)
      end

      # The memo hash for the request in flight, or nil when there is none.
      #
      # nil means "do not cache". Outside a request — boot, a console, a rake
      # task — nothing would ever clear the entries, so a memoised answer would
      # outlive the moment that produced it. Answering live is the only safe
      # behaviour there, and it is also what happens when the optional
      # `request_store` gem is not installed at all.
      def cache
        return nil unless defined?(::RequestStore)
        return nil unless ::RequestStore.respond_to?(:active?) && ::RequestStore.active?

        ::RequestStore.store[STORE_KEY] ||= {}
      end

      # Drops everything memoised for the request in flight. Call it after
      # mutating a feature mid-request if later call sites in that same request
      # must observe the new state.
      def clear!
        ::RequestStore.store.delete(STORE_KEY) if defined?(::RequestStore)
        nil
      end
    end

    def enabled?(feature_name, context = {})
      cache = RequestStoreIntegration.cache
      return super unless cache

      key = [feature_name.to_s, context]
      # `key?` rather than a nil check: `false` is a perfectly good answer to memoise.
      return cache[key] if cache.key?(key)

      cache[key] = super
    end
  end
end
