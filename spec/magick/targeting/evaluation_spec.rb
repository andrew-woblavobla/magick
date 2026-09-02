# frozen_string_literal: true

require 'spec_helper'

# Targeting is evaluated inline by Feature#check_enabled / #check_targeting.
# The Magick::Targeting::* strategy classes are not on that path, so testing
# them proves nothing about what a flag returns. Every example here registers a
# real feature, applies targeting through the public API, and asserts on
# enabled?.
#
# Scope: the rules that evaluate correctly today — user, group, role, tag,
# percentage-of-users, and exclusions beating inclusions. The gate rules
# (date range, IP, custom attributes, complex conditions, variants) are covered
# once they are fixed; see issue 03.
RSpec.describe 'Targeting evaluation through Feature#enabled?' do
  # Boolean flag whose stored value stays false, so every `true` below is
  # produced by a targeting rule rather than by the flag's own value.
  def flag(name, **options)
    Magick.register_feature(name, **{ type: :boolean, default_value: false }.merge(options))
    Magick[name]
  end

  describe 'user targeting' do
    it 'enables the flag for a targeted user and for nobody else' do
      feature = flag(:user_rollout)
      feature.enable_for_user(123)

      expect(feature.enabled?(user_id: 123)).to be true
      expect(feature.enabled?(user_id: 456)).to be false
    end

    it 'stays off when the context carries no user' do
      feature = flag(:user_rollout)
      feature.enable_for_user(123)

      expect(feature.enabled?).to be false
    end

    it 'matches Integer and String ids interchangeably' do
      feature = flag(:user_rollout)
      feature.enable_for_user(123)

      expect(feature.enabled?(user_id: '123')).to be true
    end

    it 'targets every user added to the list' do
      feature = flag(:user_rollout)
      feature.enable_for_user(1)
      feature.enable_for_user(2)

      expect(feature.enabled?(user_id: 1)).to be true
      expect(feature.enabled?(user_id: 2)).to be true
      expect(feature.enabled?(user_id: 3)).to be false
    end

    it 'drops a user again on disable_for_user' do
      feature = flag(:user_rollout)
      feature.enable_for_user(1)
      feature.enable_for_user(2)
      feature.disable_for_user(2)

      expect(feature.enabled?(user_id: 1)).to be true
      expect(feature.enabled?(user_id: 2)).to be false
    end

    it 'gives the same answer through Magick.enabled? and Magick.enabled_for?' do
      flag(:user_rollout).enable_for_user(123)

      expect(Magick.enabled?(:user_rollout, user_id: 123)).to be true
      expect(Magick.enabled_for?(:user_rollout, { id: 123 })).to be true
      expect(Magick.enabled_for?(:user_rollout, { id: 456 })).to be false
    end
  end

  describe 'group targeting' do
    it 'enables the flag for a targeted group and for nobody else' do
      feature = flag(:group_rollout)
      feature.enable_for_group('beta_testers')

      expect(feature.enabled?(group: 'beta_testers')).to be true
      expect(feature.enabled?(group: 'everyone_else')).to be false
      expect(feature.enabled?).to be false
    end

    it 'targets every group added to the list' do
      feature = flag(:group_rollout)
      feature.enable_for_group('beta_testers')
      feature.enable_for_group('staff')

      expect(feature.enabled?(group: 'staff')).to be true
    end

    it 'drops a group again on disable_for_group' do
      feature = flag(:group_rollout)
      feature.enable_for_group('beta_testers')
      feature.disable_for_group('beta_testers')

      expect(feature.enabled?(group: 'beta_testers')).to be false
    end

    it 'reads the group off an object passed to enabled_for?' do
      flag(:group_rollout).enable_for_group('beta_testers')
      member = double('User', id: 7, group: 'beta_testers')
      outsider = double('User', id: 8, group: 'everyone_else')

      expect(Magick.enabled_for?(:group_rollout, member)).to be true
      expect(Magick.enabled_for?(:group_rollout, outsider)).to be false
    end
  end

  describe 'role targeting' do
    it 'enables the flag for a targeted role and for nobody else' do
      feature = flag(:role_rollout)
      feature.enable_for_role('admin')

      expect(feature.enabled?(role: 'admin')).to be true
      expect(feature.enabled?(role: 'member')).to be false
      expect(feature.enabled?).to be false
    end

    it 'targets every role added to the list' do
      feature = flag(:role_rollout)
      feature.enable_for_role('admin')
      feature.enable_for_role('support')

      expect(feature.enabled?(role: 'support')).to be true
    end

    it 'drops a role again on disable_for_role' do
      feature = flag(:role_rollout)
      feature.enable_for_role('admin')
      feature.disable_for_role('admin')

      expect(feature.enabled?(role: 'admin')).to be false
    end

    it 'reads the role off an object passed to enabled_for?' do
      flag(:role_rollout).enable_for_role('admin')

      expect(Magick.enabled_for?(:role_rollout, { id: 7, role: 'admin' })).to be true
      expect(Magick.enabled_for?(:role_rollout, { id: 8, role: 'member' })).to be false
    end
  end

  describe 'tag targeting' do
    it 'enables the flag when the context carries the targeted tag' do
      feature = flag(:tag_rollout)
      feature.enable_for_tag('premium')

      expect(feature.enabled?(tags: ['premium'])).to be true
      expect(feature.enabled?(tags: ['free'])).to be false
      expect(feature.enabled?).to be false
    end

    it 'matches when any one context tag is targeted' do
      feature = flag(:tag_rollout)
      feature.enable_for_tag('premium')

      expect(feature.enabled?(tags: %w[free premium other])).to be true
    end

    it 'matches when the context carries any one of several targeted tags' do
      feature = flag(:tag_rollout)
      feature.enable_for_tag('premium')
      feature.enable_for_tag('beta')

      expect(feature.enabled?(tags: ['beta'])).to be true
    end

    it 'compares tags as strings, so numeric tag ids match' do
      feature = flag(:tag_rollout)
      feature.enable_for_tag('1')

      expect(feature.enabled?(tags: [1])).to be true
    end

    it 'drops a tag again on disable_for_tag' do
      feature = flag(:tag_rollout)
      feature.enable_for_tag('premium')
      feature.disable_for_tag('premium')

      expect(feature.enabled?(tags: ['premium'])).to be false
    end

    it 'extracts tags from an object passed to enabled_for?' do
      flag(:tag_rollout).enable_for_tag('1')
      tagged = double('User', id: 123, tags: [double(id: 1), double(id: 2)])
      untagged = double('User', id: 124, tags: [double(id: 9)])

      expect(Magick.enabled_for?(:tag_rollout, tagged)).to be true
      expect(Magick.enabled_for?(:tag_rollout, untagged)).to be false
    end
  end

  describe 'inclusion rules combine as any-of' do
    it 'matches on the group even when the user id is not targeted' do
      feature = flag(:mixed_rollout)
      feature.enable_for_user(1)
      feature.enable_for_group('staff')

      expect(feature.enabled?(user_id: 2, group: 'staff')).to be true
      expect(feature.enabled?(user_id: 1, group: 'other')).to be true
      expect(feature.enabled?(user_id: 2, group: 'other')).to be false
    end
  end

  describe 'percentage-of-users bucketing' do
    # Membership is a pure function of MD5("<feature name>:<user id>"), so the
    # same user always lands in the same bucket for the same flag.
    def members(feature, user_ids)
      user_ids.select { |id| feature.enabled?(user_id: id) }
    end

    it 'includes everyone at 100%' do
      feature = flag(:percentage_rollout)
      feature.enable_percentage_of_users(100)

      expect(members(feature, 1..50)).to eq((1..50).to_a)
    end

    it 'stays off for a context without a user id' do
      feature = flag(:percentage_rollout)
      feature.enable_percentage_of_users(100)

      expect(feature.enabled?).to be false
    end

    it 'gives the same user the same answer on every call' do
      feature = flag(:percentage_rollout)
      feature.enable_percentage_of_users(50)

      first = feature.enabled?(user_id: 42)
      expect(Array.new(20) { feature.enabled?(user_id: 42) }).to all(be first)
    end

    it 'buckets a user the same way whether the id is an Integer or a String' do
      feature = flag(:percentage_rollout)
      feature.enable_percentage_of_users(50)

      (1..30).each do |id|
        expect(feature.enabled?(user_id: id.to_s)).to be feature.enabled?(user_id: id)
      end
    end

    it 'assigns users deterministically, not randomly' do
      # user 1 hashes into bucket 48 and user 3 into bucket 98 for this flag
      # name, so a 50% rollout takes the first and not the second.
      feature = flag(:percentage_rollout)
      feature.enable_percentage_of_users(50)

      expect(feature.enabled?(user_id: 1)).to be true
      expect(feature.enabled?(user_id: 3)).to be false
    end

    it 'only ever adds users as the percentage is raised' do
      feature = flag(:percentage_rollout)
      user_ids = (1..300).to_a

      feature.enable_percentage_of_users(25)
      quarter = members(feature, user_ids)
      feature.enable_percentage_of_users(50)
      half = members(feature, user_ids)
      feature.enable_percentage_of_users(100)
      everyone = members(feature, user_ids)

      expect(half).to include(*quarter)
      expect(everyone).to include(*half)
    end

    it 'covers roughly the requested share of a large user base' do
      feature = flag(:percentage_rollout)
      feature.enable_percentage_of_users(50)

      expect(members(feature, 1..2000).size).to be_within(150).of(1000)
    end

    it 'buckets each flag independently, so rollouts do not line up' do
      one = flag(:percentage_rollout_one)
      two = flag(:percentage_rollout_two)
      one.enable_percentage_of_users(50)
      two.enable_percentage_of_users(50)

      expect(members(one, 1..200)).not_to eq(members(two, 1..200))
    end

    it 'falls back to the stored value once the rollout is removed' do
      feature = flag(:percentage_rollout)
      feature.enable_percentage_of_users(100)
      feature.disable_percentage_of_users

      expect(feature.enabled?(user_id: 1)).to be false
    end
  end

  describe 'exclusions take priority over inclusions' do
    it 'excludes a user who is also on the user list' do
      feature = flag(:exclusion_demo)
      feature.enable_for_user(1)
      feature.enable_for_user(2)
      feature.exclude_user(2)

      expect(feature.enabled?(user_id: 1)).to be true
      expect(feature.enabled?(user_id: 2)).to be false
    end

    it 'excludes a user who would otherwise qualify through their group' do
      feature = flag(:exclusion_demo)
      feature.enable_for_group('beta_testers')
      feature.exclude_user(9)

      expect(feature.enabled?(user_id: 9, group: 'beta_testers')).to be false
      expect(feature.enabled?(user_id: 10, group: 'beta_testers')).to be true
    end

    it 'excludes a whole group that is also on the group list' do
      feature = flag(:exclusion_demo)
      feature.enable_for_group('beta_testers')
      feature.exclude_group('beta_testers')

      expect(feature.enabled?(group: 'beta_testers')).to be false
    end

    it 'excludes a role that would otherwise qualify through the user list' do
      feature = flag(:exclusion_demo)
      feature.enable_for_user(5)
      feature.exclude_role('suspended')

      expect(feature.enabled?(user_id: 5, role: 'suspended')).to be false
      expect(feature.enabled?(user_id: 5, role: 'member')).to be true
    end

    it 'excludes on any one matching tag' do
      feature = flag(:exclusion_demo)
      feature.enable_for_tag('premium')
      feature.exclude_tag('legacy_tier')

      expect(feature.enabled?(tags: ['premium'])).to be true
      expect(feature.enabled?(tags: %w[premium legacy_tier])).to be false
    end

    it 'excludes an IP range that would otherwise qualify through the user list' do
      feature = flag(:exclusion_demo)
      feature.enable_for_user(5)
      feature.exclude_ip_addresses('10.0.0.0/8')

      expect(feature.enabled?(user_id: 5, ip_address: '10.1.2.3')).to be false
      expect(feature.enabled?(user_id: 5, ip_address: '192.168.1.1')).to be true
    end

    it 'beats a 100% rollout' do
      feature = flag(:exclusion_demo)
      feature.enable_percentage_of_users(100)
      feature.exclude_user(1)

      expect(feature.enabled?(user_id: 1)).to be false
      expect(feature.enabled?(user_id: 2)).to be true
    end

    it 'beats a globally enabled flag' do
      feature = flag(:exclusion_demo)
      feature.enable
      feature.exclude_user(123)

      expect(feature.enabled?(user_id: 123)).to be false
      expect(feature.enabled?(user_id: 456)).to be true
    end

    it 'stops excluding once the exclusion is removed' do
      feature = flag(:exclusion_demo)
      feature.enable_for_user(1)
      feature.exclude_user(1)
      feature.remove_user_exclusion(1)

      expect(feature.enabled?(user_id: 1)).to be true
    end
  end
end
