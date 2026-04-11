defmodule DodoRouter.Accounts.UserNotifier do
  import Swoosh.Email

  alias DodoRouter.Mailer
  alias DodoRouter.Accounts.User

  # Delivers the email using the application mailer.
  defp deliver(recipient, subject, body) do
    from_email = Application.get_env(:dodo_router, :email_from, "support@mail.dodorouter.com")
    reply_to = Application.get_env(:dodo_router, :email_reply_to, "support@dodorouter.com")

    email =
      new()
      |> to(recipient)
      |> from({"DodoRouter", from_email})
      |> maybe_reply_to(reply_to)
      |> subject(subject)
      |> text_body(body)

    with {:ok, _metadata} <- Mailer.deliver(email) do
      {:ok, email}
    end
  end

  defp maybe_reply_to(email, nil), do: email
  defp maybe_reply_to(email, reply_to), do: reply_to(email, reply_to)

  @doc """
  Deliver instructions to update a user email.
  """
  def deliver_update_email_instructions(user, url) do
    deliver(user.email, "Update email instructions", """

    ==============================

    Hi #{user.email},

    You can change your email by visiting the URL below:

    #{url}

    If you didn't request this change, please ignore this.

    ==============================
    """)
  end

  @doc """
  Deliver instructions to log in with a magic link.
  """
  def deliver_login_instructions(user, url) do
    case user do
      %User{confirmed_at: nil} -> deliver_confirmation_instructions(user, url)
      _ -> deliver_magic_link_instructions(user, url)
    end
  end

  defp deliver_magic_link_instructions(user, url) do
    deliver(user.email, "Log in instructions", """

    ==============================

    Hi #{user.email},

    You can log into your account by visiting the URL below:

    #{url}

    If you didn't request this email, please ignore this.

    ==============================
    """)
  end

  defp deliver_confirmation_instructions(user, url) do
    deliver(user.email, "Confirmation instructions", """

    ==============================

    Hi #{user.email},

    You can confirm your account by visiting the URL below:

    #{url}

    If you didn't create an account with us, please ignore this.

    ==============================
    """)
  end
end
