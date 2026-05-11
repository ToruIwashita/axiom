Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # === axiom Phase 2.2: REST API(02_§4.7 確定仕様) ===
  namespace :api do
    namespace :v1 do
      resources :strategy_definitions, only: %i[index show create update] do
        resources :revisions, controller: "strategy_revisions", only: %i[index show create] do
          post :approve, on: :member
          post :promote, on: :member
          post :deprecate, on: :member
          post :archive, on: :member
        end
        resources :backtesting_runs, only: %i[create]
      end

      resources :backtesting_runs, only: %i[index show] do
        post :cancel, on: :member
        resources :trades, controller: "backtesting_run_trades", only: %i[index]
        resource :equity_curve, controller: "backtesting_run_equity_curve", only: %i[show]
      end

      # Phase 3.4b Step 3.4-5/6/7: LiveTrading::Session API
      resources :live_trading_sessions, only: %i[index show create] do
        post :stop, on: :member
        collection do
          post :emergency_stop
        end
        resources :trades, controller: "live_trading_session_trades", only: %i[index]
        resource :position, controller: "live_trading_session_positions", only: %i[show]
      end

      # Phase 3.4b Step 3.4-8: LiveTrading::Trade 単体取得 API(Trade + Order[] + AlgoOrder[] + Fill[])
      resources :live_trading_trades, only: %i[show]

      post "market_data/sync", to: "market_data#sync"
    end
  end

  # === axiom Phase 2.3: UI ルート ===
  resources :strategy_definitions do
    resources :revisions, controller: "strategy_revisions", only: %i[index show new create] do
      post :approve, on: :member
    end
    resources :backtesting_runs, only: %i[new create]
  end
  resources :backtesting_runs, only: %i[index show] do
    post :cancel, on: :member
  end

  # Phase 3.4b Step 3.4-9 / 3.4-10: LiveTrading::Session UI ルート
  resources :live_trading_sessions, only: %i[index show new create] do
    post :stop, on: :member
    collection do
      post :emergency_stop
    end
  end

  # Phase 3.4b Step 3.4-12: LiveTrading::Trade 単体表示 UI ルート
  resources :live_trading_trades, only: %i[show]

  # Defines the root path route ("/")
  root "backtesting_runs#index"
end
