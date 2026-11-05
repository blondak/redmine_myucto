get 'projects/:project_id/myucto', to: 'myucto_projects#show', as: :project_myucto
patch 'projects/:project_id/myucto', to: 'myucto_projects#update'
post 'projects/:project_id/myucto/retry', to: 'myucto_projects#retry_events', as: :retry_project_myucto
post 'projects/:project_id/myucto/bindings/:id/attach', to: 'myucto_projects#attach_invoice', as: :attach_project_myucto_invoice
post 'projects/:project_id/myucto/events/:id/resume', to: 'myucto_projects#resume_event', as: :resume_project_myucto_event
post 'myucto/test_connection', to: 'myucto_projects#test_connection', as: :test_myucto_connection

post 'myucto/suppliers', to: 'myucto_projects#suppliers', as: :myucto_suppliers

post 'projects/:project_id/myucto/queue_existing', to: 'myucto_projects#queue_existing', as: :queue_existing_project_myucto
