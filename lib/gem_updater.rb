require_relative 'cache'
require_relative 'gem_store'
require 'rubygems'
require 'yard'

class GemVersion
  attr_accessor :name, :version, :platform

  def initialize(name, version, platform)
    @name, @version, @platform = name.to_s, version.to_s, platform.to_s
  end

  def to_s
    platform == "ruby" ? version : [version,platform].join(',')
  end
end

class GemUpdater
  include YARD::Server

  attr_accessor :gem, :settings, :app

  class << self
    def fetch_remote_gems
      libs = {}
      if Gem::VERSION < '2.0'
        Gem::SpecFetcher.fetcher.list(true).values.flatten(1).each do |info|
          (libs[info[0]] ||= []) << GemVersion.new(*info)
        end
      else # RubyGems 2.x API
        Gem::SpecFetcher.fetcher.available_specs(:released).first.values.flatten(1).each do |tuple|
          (libs[tuple.name] ||= []) << GemVersion.new(tuple.name, tuple.version, tuple.platform)
        end
      end

      libs
    end

    def update_remote_gems
      libs = fetch_remote_gems
      store = GemStore.new
      changed_gems = {}
      removed_gems = []
      RemoteGem.all.each do |row|
        changed_gems[row.name] = row.versions.split(' ')
      end

      RemoteGem.db.transaction do
        libs.each do |name, versions|
          versions = pick_best_versions(versions)
          if changed_gems[name] && (versions|changed_gems[name]).size == versions.size
            changed_gems.delete(name)
          else
            store[name] = versions
          end
        end
      end

      changed_gems.keys.each do |gem_name|
        flush_cache(gem_name)
      end

      # deal with deleted gems
      changed_gems.keys.each do |gem_name|
        next if libs[gem_name]
        removed_gems << gem_name
        changed_gems.delete(gem_name)
        store.delete(gem_name)
      end

      [changed_gems, removed_gems]
    end

    def pick_best_versions(versions)
      seen = {}
      uniqversions = []
      versions.each do |ver|
        uniqversions |= [ver.version]
        (seen[ver.version] ||= []).send(ver.platform == "ruby" ? :unshift : :push, ver)
      end
      uniqversions.map {|v| seen[v].first.to_s }
    end

    def flush_cache(gem_name)
      Cache.invalidate("/gems", "/gems/~#{gem_name[0, 1]}", "/gems/#{gem_name}")
    end
  end

  def initialize(app, name, version, platform='ruby')
    self.settings = app.settings
    self.app = app
    self.gem = GemVersion.new(name, version, platform)
  end

  def register
    store = GemStore.new
    libs = (store[gem.name] || []).map {|v| v.version }
    store[gem.name] = libs | [gem.version]
  end

  # TODO: improve this cache invalidation to be version specific
  def flush_cache
    self.class.flush_cache(gem.name)
  end
end
