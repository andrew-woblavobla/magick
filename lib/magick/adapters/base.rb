# frozen_string_literal: true

module Magick
  module Adapters
    class Base
      def get(feature_name, key)
        raise NotImplementedError, "#{self.class} must implement #get"
      end

      def set(feature_name, key, value)
        raise NotImplementedError, "#{self.class} must implement #set"
      end

      def delete(feature_name)
        raise NotImplementedError, "#{self.class} must implement #delete"
      end

      def exists?(feature_name)
        raise NotImplementedError, "#{self.class} must implement #exists?"
      end

      def all_features
        raise NotImplementedError, "#{self.class} must implement #all_features"
      end

      # Load all keys for a single feature in one call (override for efficiency)
      def get_all_data(feature_name)
        {}
      end

      # Bulk load all features' data in one call (override for efficiency)
      def load_all_features_data
        {}
      end

      # Bulk set multiple keys for a feature in one call.
      # Subclasses MUST implement this — a no-op default silently drops
      # bulk writes, which is why this used to cause hard-to-diagnose lost
      # updates for custom adapters (audit P2-Co6).
      def set_all_data(feature_name, data_hash)
        raise NotImplementedError,
              "#{self.class} must implement #set_all_data (feature=#{feature_name}, keys=#{data_hash.keys.inspect})"
      end

      # Remove a single key from a feature's data, leaving the rest intact.
      # Subclasses MUST implement this — there is no way to express "delete one
      # key" in terms of the other primitives, and retention (pruning the
      # version history hot window) depends on it.
      def delete_key(feature_name, key)
        raise NotImplementedError,
              "#{self.class} must implement #delete_key (feature=#{feature_name}, key=#{key})"
      end

      # Atomically allocate the next number in a monotonic counter stored under
      # (feature_name, key) and return it. The result is always greater than
      # both the stored value and +floor+; callers pass the highest number they
      # can already see as +floor+ so a store that lost its counter (Redis
      # flush, restored dump, upgrade from a release that had none) resumes
      # above the surviving data instead of restarting at 1 and overwriting it.
      #
      # Adapters backed by a store SHARED BETWEEN PROCESSES must override this
      # with a genuinely atomic primitive (Redis HINCRBY, a row lock, a database
      # sequence). This default is a plain read-modify-write: it is correct for
      # a store only one process can reach, and will hand the same number to two
      # processes that call it concurrently.
      def next_sequence(feature_name, key, floor: 0)
        value = [get(feature_name, key).to_i, floor.to_i].max + 1
        set(feature_name, key, value)
        value
      end
    end
  end
end
