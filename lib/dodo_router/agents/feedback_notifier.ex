defmodule DodoRouter.Agents.FeedbackNotifier do
  @moduledoc """
  Mails agent-submitted feedback to the admins.

  The MCP surface exists because agents use it unattended; the feedback
  that shaped it (get_eval payload size, missing log ids, silent judge
  quota contention) arrived as prose relayed by hand. This is the direct
  channel: one tool call, one email.
  """

  import Swoosh.Email

  alias DodoRouter.Mailer

  @admin_email "hgezim@dodorouter.com"

  def deliver_feedback(user_email, message) do
    from_email = Application.get_env(:dodo_router, :email_from, "support@mail.dodorouter.com")

    email =
      new()
      |> to(@admin_email)
      |> from({"DodoRouter", from_email})
      |> reply_to(user_email)
      |> subject("Agent feedback via MCP (account: #{user_email})")
      |> text_body("""
      Feedback submitted through the send_feedback MCP tool.

      Account: #{user_email}

      #{message}
      """)

    with {:ok, _metadata} <- Mailer.deliver(email) do
      {:ok, email}
    end
  end
end
