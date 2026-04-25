require_relative "boot"

require "rails"
# Pick the frameworks you want:
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "active_storage/engine"
require "action_controller/railtie"
require "action_mailer/railtie"
require "action_mailbox/engine"
require "action_text/engine"
require "action_view/railtie"
require "action_cable/engine"
# require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module Axiom
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # === 名前空間付きautoload設定 ===
    # Rails 8.1 デフォルトでは app/* が個別autoload rootとして登録されるため,
    # app/domain/foo.rb → Foo (ルート直下) と解釈されてしまう
    # 本プロジェクトは Domain::Foo / ApplicationServices::Foo / Infrastructure::Foo の
    # 名前空間を設計書で前提とするため, Zeitwerk の push_dir + namespace で
    # 明示的に名前空間付きautoloadを構成する

    # まず対象ディレクトリを標準autoload_pathsから除外
    %w[domain application_services infrastructure].each do |ns|
      path = Rails.root.join("app", ns).to_s
      config.autoload_paths.delete(path)
      config.eager_load_paths.delete(path)
    end

    # 名前空間モジュールを事前定義 (push_dir時の namespace: 指定に必要)
    ::Domain = Module.new unless defined?(::Domain)
    ::ApplicationServices = Module.new unless defined?(::ApplicationServices)
    ::Infrastructure = Module.new unless defined?(::Infrastructure)

    # Rails の :set_autoload_paths initializer の前に Zeitwerk loader へ
    # 名前空間付きで push_dir することで app/{domain,application_services,infrastructure}/*
    # が Domain:: / ApplicationServices:: / Infrastructure:: の名前空間で autoload される
    initializer :setup_namespaced_autoload, before: :set_autoload_paths do
      loader = Rails.autoloaders.main
      loader.push_dir(Rails.root.join("app/domain").to_s, namespace: ::Domain)
      loader.push_dir(Rails.root.join("app/application_services").to_s, namespace: ::ApplicationServices)
      loader.push_dir(Rails.root.join("app/infrastructure").to_s, namespace: ::Infrastructure)
    end

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")

    # Don't generate system test files.
    config.generators.system_tests = nil
  end
end
