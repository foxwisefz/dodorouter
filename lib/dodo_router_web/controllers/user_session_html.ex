defmodule DodoRouterWeb.UserSessionHTML do
  use DodoRouterWeb, :html

  embed_templates "user_session_html/*"

  defp local_mail_adapter? do
    Application.get_env(:dodo_router, DodoRouter.Mailer)[:adapter] == Swoosh.Adapters.Local
  end
end
