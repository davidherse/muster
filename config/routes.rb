Rails.application.routes.draw do
  resource :session
  resource :registration, only: %i[ new create ]
  resources :passwords, param: :token
  get "activate/:token", to: "activations#show", as: :activation

  resources :estimates do
    member do
      get :csv
      get :status
      post :regenerate
    end
  end
  resources :price_book_items, path: "price-book"
  resources :training_documents, path: "training", only: %i[ index new create destroy ]

  get  "onboarding",          to: "onboarding#uploads",       as: :onboarding
  post "onboarding/uploads",  to: "onboarding#create_upload", as: :onboarding_uploads
  get  "onboarding/template", to: "onboarding#template",      as: :onboarding_template
  get  "onboarding/status",   to: "onboarding#status",        as: :onboarding_status
  post "onboarding/agree",    to: "onboarding#agree",         as: :onboarding_agree
  post "onboarding/skip",     to: "onboarding#skip",          as: :onboarding_skip

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  get "up" => "rails/health#show", as: :rails_health_check

  root "pages#home"
  resources :early_access_signups, only: :create
end
