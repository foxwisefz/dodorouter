defmodule Mix.Tasks.Billing.SetupStripe do
  @shortdoc "Idempotently creates the Stripe product, price, and webhook endpoint"

  @moduledoc """
  Sets up Stripe for DodoRouter billing. Safe to run repeatedly — every step
  is find-or-create, keyed on stable identifiers (price `lookup_key`, product
  metadata, webhook URL). Nothing existing is ever mutated or deleted.

      STRIPE_SECRET_KEY=sk_test_... mix billing.setup_stripe --host https://dodorouter.com

  Run it once with a test key to verify, then once with the live key. The
  task runs entirely from your machine against the Stripe API; it does not
  touch the server.

  ## Options

    * `--host` — public origin of the deployed app (e.g. `https://dodorouter.com`).
      Required to create the webhook endpoint; omit it (e.g. for local dev,
      where `stripe listen` replaces webhooks) to skip that step.
    * `--dry-run` — print what would be created without calling any
      write endpoints.
    * `--lookup-key` — price lookup key (default: `dodo_router_monthly_19`,
      must match `BILLING_PRICE_LOOKUP_KEY` on the server).

  ## What it ensures

    1. Product "DodoRouter Monthly" (found via `metadata.dodo_router_plan=monthly`)
    2. Price $19.00 USD / month with the lookup key
    3. Webhook endpoint at `<host>/webhooks/stripe` subscribed to the events
       the app handles. The signing secret is printed **only on creation** —
       Stripe never shows it again. To rotate it, delete the endpoint in the
       Stripe dashboard and re-run this task.
  """

  use Mix.Task

  @product_metadata_key "dodo_router_plan"
  @product_metadata_value "monthly"
  @product_name "DodoRouter Monthly"
  @unit_amount 1900
  @currency "usd"
  @webhook_path "/webhooks/stripe"
  @webhook_events ~w(
    checkout.session.completed
    customer.subscription.created
    customer.subscription.updated
    customer.subscription.deleted
  )

  @impl true
  def run(args) do
    {opts, _rest} =
      OptionParser.parse!(args,
        strict: [host: :string, dry_run: :boolean, lookup_key: :string]
      )

    api_key =
      System.get_env("STRIPE_SECRET_KEY") ||
        Mix.raise(
          "STRIPE_SECRET_KEY is not set. Run: STRIPE_SECRET_KEY=sk_... mix billing.setup_stripe"
        )

    mode = if String.starts_with?(api_key, "sk_live"), do: "LIVE", else: "TEST"
    dry_run? = Keyword.get(opts, :dry_run, false)
    lookup_key = Keyword.get(opts, :lookup_key, "dodo_router_monthly_19")
    host = opts[:host] && String.trim_trailing(opts[:host], "/")

    {:ok, _} = Application.ensure_all_started(:stripity_stripe)
    Application.put_env(:stripity_stripe, :api_key, api_key)

    Mix.shell().info("Stripe mode: #{mode}#{if dry_run?, do: " (dry run)"}")

    price = ensure_price(lookup_key, dry_run?)
    webhook_secret = ensure_webhook(host, dry_run?)

    print_summary(lookup_key, price, webhook_secret, host, mode)
  end

  defp ensure_price(lookup_key, dry_run?) do
    case Stripe.Price.list(%{lookup_keys: [lookup_key], active: true}) do
      {:ok, %{data: [price | _]}} ->
        Mix.shell().info("✓ Price exists: #{price.id} (lookup_key=#{lookup_key})")
        price

      {:ok, %{data: []}} ->
        product = ensure_product(dry_run?)

        if dry_run? do
          Mix.shell().info("→ Would create price: $19.00 USD/month, lookup_key=#{lookup_key}")
          nil
        else
          {:ok, price} =
            request!(
              Stripe.Price.create(%{
                product: product.id,
                unit_amount: @unit_amount,
                currency: @currency,
                recurring: %{interval: "month"},
                lookup_key: lookup_key
              }),
              "create price"
            )

          Mix.shell().info("✓ Created price: #{price.id} (lookup_key=#{lookup_key})")
          price
        end

      {:error, error} ->
        Mix.raise("Failed to list prices: #{inspect(error)}")
    end
  end

  defp ensure_product(dry_run?) do
    query = "metadata['#{@product_metadata_key}']:'#{@product_metadata_value}'"

    case Stripe.Product.search(%{query: query}) do
      {:ok, %{data: [product | _]}} ->
        Mix.shell().info("✓ Product exists: #{product.id} (#{product.name})")
        product

      {:ok, %{data: []}} ->
        if dry_run? do
          Mix.shell().info("→ Would create product: #{@product_name}")
          %{id: "(dry-run)"}
        else
          {:ok, product} =
            request!(
              Stripe.Product.create(%{
                name: @product_name,
                metadata: %{@product_metadata_key => @product_metadata_value}
              }),
              "create product"
            )

          Mix.shell().info("✓ Created product: #{product.id}")
          product
        end

      {:error, error} ->
        Mix.raise("Failed to search products: #{inspect(error)}")
    end
  end

  defp ensure_webhook(nil, _dry_run?) do
    Mix.shell().info("– Skipping webhook endpoint (no --host given; use `stripe listen` locally)")
    nil
  end

  defp ensure_webhook(host, dry_run?) do
    url = host <> @webhook_path

    case Stripe.WebhookEndpoint.list(%{limit: 100}) do
      {:ok, %{data: endpoints}} ->
        case Enum.find(endpoints, &(&1.url == url)) do
          %{id: id} ->
            Mix.shell().info("✓ Webhook endpoint exists: #{id} (#{url})")

            Mix.shell().info(
              "  (signing secret is only shown at creation — see moduledoc to rotate)"
            )

            nil

          nil ->
            if dry_run? do
              Mix.shell().info("→ Would create webhook endpoint: #{url}")
              Mix.shell().info("  events: #{Enum.join(@webhook_events, ", ")}")
              nil
            else
              {:ok, endpoint} =
                request!(
                  Stripe.WebhookEndpoint.create(%{
                    url: url,
                    enabled_events: @webhook_events,
                    description: "DodoRouter billing sync"
                  }),
                  "create webhook endpoint"
                )

              Mix.shell().info("✓ Created webhook endpoint: #{endpoint.id} (#{url})")
              endpoint.secret
            end
        end

      {:error, error} ->
        Mix.raise("Failed to list webhook endpoints: #{inspect(error)}")
    end
  end

  defp request!({:ok, _} = ok, _label), do: ok

  defp request!({:error, error}, label) do
    Mix.raise("Failed to #{label}: #{inspect(error)}")
  end

  defp print_summary(lookup_key, price, webhook_secret, host, mode) do
    Mix.shell().info("""

    ── Server environment (#{mode}) ─────────────────────────────
    Append to ~/dodorouter/.env (then restart the service —
    env changes are not picked up by hot upgrades):

      STRIPE_SECRET_KEY=<the #{mode} secret key you just used>
      BILLING_PRICE_LOOKUP_KEY=#{lookup_key}\
    #{if webhook_secret, do: "\n  STRIPE_WEBHOOK_SECRET=#{webhook_secret}", else: ""}\
    #{if is_nil(webhook_secret) and host, do: "\n  STRIPE_WEBHOOK_SECRET=<unchanged — kept from webhook creation>", else: ""}

    Optional:
      BILLING_TRIAL_DAYS=0        # flip to e.g. 14 to enable card-upfront trials
    ─────────────────────────────────────────────────────────────
    #{if price, do: "Price: #{price.id}", else: "Price: (dry run)"}
    """)
  end
end
