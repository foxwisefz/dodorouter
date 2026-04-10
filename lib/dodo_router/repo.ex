defmodule DodoRouter.Repo do
  use Ecto.Repo,
    otp_app: :dodo_router,
    adapter: Ecto.Adapters.Postgres
end
