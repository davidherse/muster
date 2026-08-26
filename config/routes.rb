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
      post :answer_questions
    end
  end
  resources :price_book_items, path: "price-book"
  resources :training_documents, path: "training", only: %i[ index new create destroy ]
  resources :templates, only: %i[ index edit update ] do
    collection do
      post :customise
      post :rederive
      post :accept
      delete :discard
      get :status
    end
  end

  resource :team, controller: "team", only: :show do
    patch :rename                                   # rename_team_path
  end
  post   "team/members",                to: "team#create",     as: :team_members
  delete "team/members/:id",            to: "team#destroy",    as: :team_member
  post   "team/members/:id/reset_link", to: "team#reset_link", as: :reset_link_team_member

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
