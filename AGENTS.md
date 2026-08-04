This is a web application written using the Phoenix web framework. It is an LLM proxy/router that accepts requests from OpenAI-compatible and Anthropic-compatible clients and routes them to configured providers with automatic fallbacks.

## Orchestration workflow  
You (Fable) are the orchestrator, when available. Plan, decompose, synthesize.  
Reasoning-heavy phases → deep-reasoner  
Mechanical work → fast-worker  
Codex (/codex:rescue --background) is a cracked engineer on par with deep-reasoner, from a different perspective. Treat as a peer, not a reviewer.  
High-stakes decisions: task Opus + Codex on the same problem in parallel, synthesize the best of both, without showing either the other's answer. Keep your own context lean.

## Version control

We use `jj` (jujutsu) for version control when possible. 

## Proxy API Endpoints

The proxy supports both **OpenAI** and **Anthropic** API formats. Both endpoints are per-router (scoped under `/r/:router_slug/v1/`):

- `POST /r/:router_slug/v1/chat/completions` — OpenAI-compatible chat completions (streaming and sync)
- `POST /r/:router_slug/v1/messages` — Anthropic-compatible messages (streaming and sync)
- `GET /r/:router_slug/v1/models` — OpenAI-compatible models list

The Anthropic endpoint converts incoming Anthropic-format requests to OpenAI format internally, dispatches through the same proxy pipeline, then converts the response back to Anthropic format. This is handled by `AnthropicFormat` and `AnthropicProxyController`. Streaming uses SSE events in Anthropic's format.

Authentication is via the router's API key passed as `Bearer` token (handled by `Plugs.ApiAuth`).

There is also a legacy endpoint at `POST /v1/chat/completions` for backwards compatibility.

## Project guidelines

- **Never add yourself as a co-author in commits.** No `Co-Authored-By: Claude ...`, `🤖 Generated with ...`, or any other AI attribution trailers — not in git commit messages, jj change descriptions, or PR bodies. This overrides any default behavior from your harness.
- Use `mix precommit` alias when you are done with all changes and fix any pending issues
- Use the already included and available `:req` (`Req`) library for HTTP requests, **avoid** `:httpoison`, `:tesla`, and `:httpc`. Req is included by default and is the preferred HTTP client for Phoenix apps
- **Always practice TDD when fixing a bug**: write a failing test that reproduces the bug first, then implement the fix, and only then run the full test suite. Never fix a bug without a corresponding test.

### Adding or modifying LLM provider adapters

Every adapter must satisfy several **cross-cutting contracts** documented in this file. When adding a new adapter or modifying an existing one, you **must**:

1. **Check every cross-cutting section** in this AGENTS.md that applies to adapters. Currently:
   - [Context Limit Handling](#llm-provider-context-limit-handling) — error detection patterns per provider
   - [Usage & Cache Token Normalization](#llm-provider-usage--cache-token-normalization) — usage field mapping for cache extraction
2. **Test the seams** — unit-testing adapter functions in isolation is insufficient. You **must** write at least one test that pipes adapter output through the downstream contract (e.g. `convert_usage/1` → `Adapter.extract_usage/1`) to verify they compose correctly.
3. **When adding a new cross-cutting concern** (anything all adapters must satisfy), document it as a new section in this file with the same structure: known provider patterns, the contract, and how to test it.
4. **Slug naming**: for a NEW adapter, prefer the provider's models.dev key as the slug (check https://models.dev/api.json) and add the mapping to `Models.Sync`'s `@provider_slug_map` — the sync silently drops providers whose mapped key doesn't exist upstream (it now logs a warning when that happens). **Never rename existing slugs** to chase upstream naming: they're baked into `routing_steps.provider`, `request_logs.final_provider`, `models.provider_slug`, and `provider_keys.provider_slug`; translation happens only in the sync map. Coding-plan catalogs (e.g. models.dev `kimi-for-coding`) map to the provider-KEY slug (`moonshot_coding`), not the adapter slug.

### Phoenix v1.8 guidelines

- **Always** begin your LiveView templates with `<Layouts.app flash={@flash} ...>` which wraps all inner content
- The `MyAppWeb.Layouts` module is aliased in the `my_app_web.ex` file, so you can use it without needing to alias it again
- Anytime you run into errors with no `current_scope` assign:
  - You failed to follow the Authenticated Routes guidelines, or you failed to pass `current_scope` to `<Layouts.app>`
  - **Always** fix the `current_scope` error by moving your routes to the proper `live_session` and ensure you pass `current_scope` as needed
- Phoenix v1.8 moved the `<.flash_group>` component to the `Layouts` module. You are **forbidden** from calling `<.flash_group>` outside of the `layouts.ex` module
- Out of the box, `core_components.ex` imports an `<.icon name="hero-x-mark" class="w-5 h-5"/>` component for for hero icons. **Always** use the `<.icon>` component for icons, **never** use `Heroicons` modules or similar
- **Always** use the imported `<.input>` component for form inputs from `core_components.ex` when available. `<.input>` is imported and using it will will save steps and prevent errors
- If you override the default input classes (`<.input class="myclass px-2 py-1 rounded-lg">)`) class with your own values, no default classes are inherited, so your
custom classes must fully style the input

### JS and CSS guidelines

- **Use Tailwind CSS classes and custom CSS rules** to create polished, responsive, and visually stunning interfaces.
- Tailwindcss v4 **no longer needs a tailwind.config.js** and uses a new import syntax in `app.css`:

      @import "tailwindcss" source(none);
      @source "../css";
      @source "../js";
      @source "../../lib/my_app_web";

- **Always use and maintain this import syntax** in the app.css file for projects generated with `phx.new`
- **Never** use `@apply` when writing raw css
- **Always** manually write your own tailwind-based components instead of using daisyUI for a unique, world-class design
- Out of the box **only the app.js and app.css bundles are supported**
  - You cannot reference an external vendor'd script `src` or link `href` in the layouts
  - You must import the vendor deps into app.js and app.css to use them
  - **Never write inline <script>custom js</script> tags within templates**

### UI/UX & design guidelines

- **Produce world-class UI designs** with a focus on usability, aesthetics, and modern design principles
- Implement **subtle micro-interactions** (e.g., button hover effects, and smooth transitions)
- Ensure **clean typography, spacing, and layout balance** for a refined, premium look
- Focus on **delightful details** like hover effects, loading states, and smooth page transitions


<!-- phoenix-gen-auth-start -->
## Authentication

- **Always** handle authentication flow at the router level with proper redirects
- **Always** be mindful of where to place routes. `phx.gen.auth` creates multiple router plugs:
  - A plug `:fetch_current_scope_for_user` that is included in the default browser pipeline
  - A plug `:require_authenticated_user` that redirects to the log in page when the user is not authenticated
  - In both cases, a `@current_scope` is assigned to the Plug connection
  - A plug `redirect_if_user_is_authenticated` that redirects to a default path in case the user is authenticated - useful for a registration page that should only be shown to unauthenticated users
- **Always let the user know in which router scopes and pipeline you are placing the route, AND SAY WHY**
- `phx.gen.auth` assigns the `current_scope` assign - it **does not assign a `current_user` assign**
- Always pass the assign `current_scope` to context modules as first argument. When performing queries, use `current_scope.user` to filter the query results
- To derive/access `current_user` in templates, **always use the `@current_scope.user`**, never use **`@current_user`** in templates
- Anytime you hit `current_scope` errors or the logged in session isn't displaying the right content, **always double check the router and ensure you are using the correct plug as described below**

### Routes that require authentication

Controller routes must be placed in a scope that sets the `:require_authenticated_user` plug:

    scope "/", AppWeb do
      pipe_through [:browser, :require_authenticated_user]

      get "/", MyControllerThatRequiresAuth, :index
    end

### Routes that work with or without authentication

Controllers automatically have the `current_scope` available if they use the `:browser` pipeline.

<!-- phoenix-gen-auth-end -->

<!-- usage-rules-start -->

<!-- phoenix:elixir-start -->
## Elixir guidelines

- Elixir lists **do not support index based access via the access syntax**

  **Never do this (invalid)**:

      i = 0
      mylist = ["blue", "green"]
      mylist[i]

  Instead, **always** use `Enum.at`, pattern matching, or `List` for index based list access, ie:

      i = 0
      mylist = ["blue", "green"]
      Enum.at(mylist, i)

- Elixir variables are immutable, but can be rebound, so for block expressions like `if`, `case`, `cond`, etc
  you *must* bind the result of the expression to a variable if you want to use it and you CANNOT rebind the result inside the expression, ie:

      # INVALID: we are rebinding inside the `if` and the result never gets assigned
      if connected?(socket) do
        socket = assign(socket, :val, val)
      end

      # VALID: we rebind the result of the `if` to a new variable
      socket =
        if connected?(socket) do
          assign(socket, :val, val)
        end

- **Never** nest multiple modules in the same file as it can cause cyclic dependencies and compilation errors
- **Never** use map access syntax (`changeset[:field]`) on structs as they do not implement the Access behaviour by default. For regular structs, you **must** access the fields directly, such as `my_struct.field` or use higher level APIs that are available on the struct if they exist, `Ecto.Changeset.get_field/2` for changesets
- Elixir's standard library has everything necessary for date and time manipulation. Familiarize yourself with the common `Time`, `Date`, `DateTime`, and `Calendar` interfaces by accessing their documentation as necessary. **Never** install additional dependencies unless asked or for date/time parsing (which you can use the `date_time_parser` package)
- Don't use `String.to_atom/1` on user input (memory leak risk)
- Predicate function names should not start with `is_` and should end in a question mark. Names like `is_thing` should be reserved for guards
- Elixir's builtin OTP primitives like `DynamicSupervisor` and `Registry`, require names in the child spec, such as `{DynamicSupervisor, name: MyApp.MyDynamicSup}`, then you can use `DynamicSupervisor.start_child(MyApp.MyDynamicSup, child_spec)`
- Use `Task.async_stream(collection, callback, options)` for concurrent enumeration with back-pressure. The majority of times you will want to pass `timeout: :infinity` as option

## Mix guidelines

- Read the docs and options before using tasks (by using `mix help task_name`)
- To debug test failures, run tests in a specific file with `mix test test/my_test.exs` or run all previously failed tests with `mix test --failed`
- `mix deps.clean --all` is **almost never needed**. **Avoid** using it unless you have good reason
<!-- phoenix:elixir-end -->

<!-- phoenix:phoenix-start -->
## Phoenix guidelines

- Remember Phoenix router `scope` blocks include an optional alias which is prefixed for all routes within the scope. **Always** be mindful of this when creating routes within a scope to avoid duplicate module prefixes.

- You **never** need to create your own `alias` for route definitions! The `scope` provides the alias, ie:

      scope "/admin", AppWeb.Admin do
        pipe_through :browser

        live "/users", UserLive, :index
      end

  the UserLive route would point to the `AppWeb.Admin.UserLive` module

- `Phoenix.View` no longer is needed or included with Phoenix, don't use it
<!-- phoenix:phoenix-end -->

<!-- phoenix:ecto-start -->
## Ecto Guidelines

- **Always** preload Ecto associations in queries when they'll be accessed in templates, ie a message that needs to reference the `message.user.email`
- Remember `import Ecto.Query` and other supporting modules when you write `seeds.exs`
- `Ecto.Schema` fields always use the `:string` type, even for `:text`, columns, ie: `field :name, :string`
- `Ecto.Changeset.validate_number/2` **DOES NOT SUPPORT the `:allow_nil` option**. By default, Ecto validations only run if a change for the given field exists and the change value is not nil, so such as option is never needed
- You **must** use `Ecto.Changeset.get_field(changeset, :field)` to access changeset fields
- Fields which are set programatically, such as `user_id`, must not be listed in `cast` calls or similar for security purposes. Instead they must be explicitly set when creating the struct
<!-- phoenix:ecto-end -->

<!-- phoenix:html-start -->
## Phoenix HTML guidelines

- Phoenix templates **always** use `~H` or .html.heex files (known as HEEx), **never** use `~E`
- **Always** use the imported `Phoenix.Component.form/1` and `Phoenix.Component.inputs_for/1` function to build forms. **Never** use `Phoenix.HTML.form_for` or `Phoenix.HTML.inputs_for` as they are outdated
- When building forms **always** use the already imported `Phoenix.Component.to_form/2` (`assign(socket, form: to_form(...))` and `<.form for={@form} id="msg-form">`), then access those forms in the template via `@form[:field]`
- **Always** add unique DOM IDs to key elements (like forms, buttons, etc) when writing templates, these IDs can later be used in tests (`<.form for={@form} id="product-form">`)
- For "app wide" template imports, you can import/alias into the `my_app_web.ex`'s `html_helpers` block, so they will be available to all LiveViews, LiveComponent's, and all modules that do `use MyAppWeb, :html` (replace "my_app" by the actual app name)

- Elixir supports `if/else` but **does NOT support `if/else if` or `if/elsif`. **Never use `else if` or `elseif` in Elixir**, **always** use `cond` or `case` for multiple conditionals.

  **Never do this (invalid)**:

      <%= if condition do %>
        ...
      <% else if other_condition %>
        ...
      <% end %>

  Instead **always** do this:

      <%= cond do %>
        <% condition -> %>
          ...
        <% condition2 -> %>
          ...
        <% true -> %>
          ...
      <% end %>

- HEEx require special tag annotation if you want to insert literal curly's like `{` or `}`. If you want to show a textual code snippet on the page in a `<pre>` or `<code>` block you *must* annotate the parent tag with `phx-no-curly-interpolation`:

      <code phx-no-curly-interpolation>
        let obj = {key: "val"}
      </code>

  Within `phx-no-curly-interpolation` annotated tags, you can use `{` and `}` without escaping them, and dynamic Elixir expressions can still be used with `<%= ... %>` syntax

- HEEx class attrs support lists, but you must **always** use list `[...]` syntax. You can use the class list syntax to conditionally add classes, **always do this for multiple class values**:

      <a class={[
        "px-2 text-white",
        @some_flag && "py-5",
        if(@other_condition, do: "border-red-500", else: "border-blue-100"),
        ...
      ]}>Text</a>

  and **always** wrap `if`'s inside `{...}` expressions with parens, like done above (`if(@other_condition, do: "...", else: "...")`)

  and **never** do this, since it's invalid (note the missing `[` and `]`):

      <a class={
        "px-2 text-white",
        @some_flag && "py-5"
      }> ...
      => Raises compile syntax error on invalid HEEx attr syntax

- **Never** use `<% Enum.each %>` or non-for comprehensions for generating template content, instead **always** use `<%= for item <- @collection do %>`
- HEEx HTML comments use `<%!-- comment --%>`. **Always** use the HEEx HTML comment syntax for template comments (`<%!-- comment --%>`)
- HEEx allows interpolation via `{...}` and `<%= ... %>`, but the `<%= %>` **only** works within tag bodies. **Always** use the `{...}` syntax for interpolation within tag attributes, and for interpolation of values within tag bodies. **Always** interpolate block constructs (if, cond, case, for) within tag bodies using `<%= ... %>`.

  **Always** do this:

      <div id={@id}>
        {@my_assign}
        <%= if @some_block_condition do %>
          {@another_assign}
        <% end %>
      </div>

  and **Never** do this – the program will terminate with a syntax error:

      <%!-- THIS IS INVALID NEVER EVER DO THIS --%>
      <div id="<%= @invalid_interpolation %>">
        {if @invalid_block_construct do}
        {end}
      </div>
<!-- phoenix:html-end -->

<!-- phoenix:liveview-start -->
## Phoenix LiveView guidelines

- **Never** use the deprecated `live_redirect` and `live_patch` functions, instead **always** use the `<.link navigate={href}>` and  `<.link patch={href}>` in templates, and `push_navigate` and `push_patch` functions LiveViews
- **Avoid LiveComponent's** unless you have a strong, specific need for them
- LiveViews should be named like `AppWeb.WeatherLive`, with a `Live` suffix. When you go to add LiveView routes to the router, the default `:browser` scope is **already aliased** with the `AppWeb` module, so you can just do `live "/weather", WeatherLive`
- Remember anytime you use `phx-hook="MyHook"` and that js hook manages its own DOM, you **must** also set the `phx-update="ignore"` attribute
- **Never** write embedded `<script>` tags in HEEx. Instead always write your scripts and hooks in the `assets/js` directory and integrate them with the `assets/js/app.js` file

### LiveView streams

- **Always** use LiveView streams for collections for assigning regular lists to avoid memory ballooning and runtime termination with the following operations:
  - basic append of N items - `stream(socket, :messages, [new_msg])`
  - resetting stream with new items - `stream(socket, :messages, [new_msg], reset: true)` (e.g. for filtering items)
  - prepend to stream - `stream(socket, :messages, [new_msg], at: -1)`
  - deleting items - `stream_delete(socket, :messages, msg)`

- When using the `stream/3` interfaces in the LiveView, the LiveView template must 1) always set `phx-update="stream"` on the parent element, with a DOM id on the parent element like `id="messages"` and 2) consume the `@streams.stream_name` collection and use the id as the DOM id for each child. For a call like `stream(socket, :messages, [new_msg])` in the LiveView, the template would be:

      <div id="messages" phx-update="stream">
        <div :for={{id, msg} <- @streams.messages} id={id}>
          {msg.text}
        </div>
      </div>

- LiveView streams are *not* enumerable, so you cannot use `Enum.filter/2` or `Enum.reject/2` on them. Instead, if you want to filter, prune, or refresh a list of items on the UI, you **must refetch the data and re-stream the entire stream collection, passing reset: true**:

      def handle_event("filter", %{"filter" => filter}, socket) do
        # re-fetch the messages based on the filter
        messages = list_messages(filter)

        {:noreply,
        socket
        |> assign(:messages_empty?, messages == [])
        # reset the stream with the new messages
        |> stream(:messages, messages, reset: true)}
      end

- LiveView streams *do not support counting or empty states*. If you need to display a count, you must track it using a separate assign. For empty states, you can use Tailwind classes:

      <div id="tasks" phx-update="stream">
        <div class="hidden only:block">No tasks yet</div>
        <div :for={{id, task} <- @stream.tasks} id={id}>
          {task.name}
        </div>
      </div>

  The above only works if the empty state is the only HTML block alongside the stream for-comprehension.

- **Never** use the deprecated `phx-update="append"` or `phx-update="prepend"` for collections

### LiveView tests

- `Phoenix.LiveViewTest` module and `LazyHTML` (included) for making your assertions
- Form tests are driven by `Phoenix.LiveViewTest`'s `render_submit/2` and `render_change/2` functions
- Come up with a step-by-step test plan that splits major test cases into small, isolated files. You may start with simpler tests that verify content exists, gradually add interaction tests
- **Always reference the key element IDs you added in the LiveView templates in your tests** for `Phoenix.LiveViewTest` functions like `element/2`, `has_element/2`, selectors, etc
- **Never** tests again raw HTML, **always** use `element/2`, `has_element/2`, and similar: `assert has_element?(view, "#my-form")`
- Instead of relying on testing text content, which can change, favor testing for the presence of key elements
- Focus on testing outcomes rather than implementation details
- Be aware that `Phoenix.Component` functions like `<.form>` might produce different HTML than expected. Test against the output HTML structure, not your mental model of what you expect it to be
- When facing test failures with element selectors, add debug statements to print the actual HTML, but use `LazyHTML` selectors to limit the output, ie:

      html = render(view)
      document = LazyHTML.from_fragment(html)
      matches = LazyHTML.filter(document, "your-complex-selector")
      IO.inspect(matches, label: "Matches")

### Form handling

#### Creating a form from params

If you want to create a form based on `handle_event` params:

    def handle_event("submitted", params, socket) do
      {:noreply, assign(socket, form: to_form(params))}
    end

When you pass a map to `to_form/1`, it assumes said map contains the form params, which are expected to have string keys.

You can also specify a name to nest the params:

    def handle_event("submitted", %{"user" => user_params}, socket) do
      {:noreply, assign(socket, form: to_form(user_params, as: :user))}
    end

#### Creating a form from changesets

When using changesets, the underlying data, form params, and errors are retrieved from it. The `:as` option is automatically computed too. E.g. if you have a user schema:

    defmodule MyApp.Users.User do
      use Ecto.Schema
      ...
    end

And then you create a changeset that you pass to `to_form`:

    %MyApp.Users.User{}
    |> Ecto.Changeset.change()
    |> to_form()

Once the form is submitted, the params will be available under `%{"user" => user_params}`.

In the template, the form form assign can be passed to the `<.form>` function component:

    <.form for={@form} id="todo-form" phx-change="validate" phx-submit="save">
      <.input field={@form[:field]} type="text" />
    </.form>

Always give the form an explicit, unique DOM ID, like `id="todo-form"`.

#### Avoiding form errors

**Always** use a form assigned via `to_form/2` in the LiveView, and the `<.input>` component in the template. In the template **always access forms this**:

    <%!-- ALWAYS do this (valid) --%>
    <.form for={@form} id="my-form">
      <.input field={@form[:field]} type="text" />
    </.form>

And **never** do this:

    <%!-- NEVER do this (invalid) --%>
    <.form for={@changeset} id="my-form">
      <.input field={@changeset[:field]} type="text" />
    </.form>

- You are FORBIDDEN from accessing the changeset in the template as it will cause errors
- **Never** use `<.form let={f} ...>` in the template, instead **always use `<.form for={@form} ...>`**, then drive all form references from the form assign as in `@form[:field]`. The UI should **always** be driven by a `to_form/2` assigned in the LiveView module that is derived from a changeset
<!-- phoenix:liveview-end -->

## LLM Provider Context Limit Handling

Context limit / context window overflow errors are **not standardized** across LLM providers. Each provider returns a different error format, status code, and message. When adding a new model, you must implement handling for its specific overflow behavior.

### Known Provider Patterns

**z.ai** — Returns HTTP 200 with `finish_reason: "model_context_window_exceeded"`:
```json
{
  "choices": [{
    "finish_reason": "model_context_window_exceeded",
    "message": { "content": "", "role": "assistant" }
  }],
  "usage": null
}
```

**Kimi (Moonshot)** — Returns HTTP 400/bad_request with error message:
```json
{
  "error": {
    "message": "Invalid request: Your request exceeded model token limit: 262144 (requested: 265359)",
    "type": "invalid_request_error"
  }
}
```

**OpenAI** — Returns error code `context_length_exceeded`.

**Anthropic** — Returns message: `"prompt is too long"`.

**Other common patterns** — `"exceeds the context window"`, `"maximum context length is N tokens"`, `"reduce the length of the messages"`, HTTP 413, or generic 400 with no body.

### Adding a New Model

When integrating a new LLM provider or model:

1. **Test with oversized context in development** — send a request with more tokens than the model's documented limit to observe the actual error response (status code, body shape, finish_reason, error codes).
2. **Document the pattern** — add the observed error format to this section.
3. **Implement detection** — add the provider-specific pattern to the context overflow detection logic (status codes, finish_reason values, error message regexes, or error codes).
4. **Standardize the error** — always return a unified error to callers, e.g. `{"error": "context_overflow", "message": "Input exceeds context window of this model"}`.

### Standardized Error Responses

When all providers fail due to context overflow, the proxy returns a standardized error in the format appropriate for the endpoint:

**OpenAI-compatible endpoint** — HTTP 400:
```json
{
  "error": {
    "message": "Input exceeds context window of this model",
    "type": "invalid_request_error",
    "code": "context_length_exceeded"
  }
}
```

**Anthropic-compatible endpoint** — HTTP 400:
```json
{
  "type": "error",
  "error": {
    "type": "invalid_request_error",
    "message": "Input exceeds context window of this model"
  }
}
```

This matches each provider's native error format so clients (Claude Code, OpenCode, etc.) understand it immediately.

### Reactive vs Proactive Handling

**Reactive handling is preferred.** Each provider uses different tokenizers (OpenAI tiktoken, Anthropic's own, Google SentencePiece, etc.), so accurate preflight token counting is unreliable. Instead:

- Detect overflow from provider responses
- Trigger fallback to next provider (which may have larger context)
- Only standardize the error when all providers fail


<!-- usage-rules-end -->

## LLM Provider Usage & Cache Token Normalization

Cache token reporting is **not standardized** across LLM providers. Each provider returns cache hit/miss data in a different location within the usage object. The proxy normalizes these in `DodoRouter.Proxy.Adapter.extract_usage/1` so the UI and cost tracking can show cache-hit percentages and savings consistently.

### The Contract

Every adapter's final response `usage` map **must** use OpenAI Chat Completions field names. When a provider uses different field names, the adapter's `convert_usage/1` (or equivalent) must rename them so `Adapter.extract_cache_read_tokens/1` finds them.

### Known Provider Patterns

**OpenAI / Groq / xAI / Mistral** — Nested under `prompt_tokens_details`:
```json
{
  "usage": {
    "prompt_tokens": 100,
    "prompt_tokens_details": { "cached_tokens": 80 }
  }
}
```

**Anthropic** — Top-level fields:
```json
{
  "usage": {
    "cache_read_input_tokens": 80,
    "cache_creation_input_tokens": 20
  }
}
```

**DeepSeek** — Top-level field:
```json
{
  "usage": { "prompt_cache_hit_tokens": 80 }
}
```

**Google (Gemini)** — Nested in `usageMetadata`:
```json
{
  "usageMetadata": { "cachedContentTokenCount": 80 }
}
```

**OpenAI Responses API (Codex)** — Nested under `input_tokens_details`:
```json
{
  "usage": {
    "input_tokens": 100,
    "input_tokens_details": { "cached_tokens": 80 }
  }
}
```
The `ResponsesAPI.convert_usage/1` must rename `input_tokens_details` → `prompt_tokens_details` so the existing extraction works.

### Adding a New Adapter

When integrating a new provider:

1. **Test with a cache-enabled request** — send a request that should trigger cache hit/miss and observe the raw usage object in the provider's response.
2. **Document the pattern** — add the observed usage field locations to this section.
3. **Normalize in the adapter** — if the adapter converts usage (e.g. `convert_usage/1`), ensure the output satisfies `Adapter.extract_cache_read_tokens/1`. This function checks (in order): `cache_read_input_tokens`, `prompt_tokens_details.cached_tokens`, `prompt_cache_hit_tokens`, `cache_read_tokens`.
4. **Test the seam** — write a test that pipes `convert_usage/1` output through `Adapter.extract_usage/1` and asserts `cache_read_tokens` is non-nil when cache data is present. Unit-testing each function in isolation is insufficient.

## Prompt Cache Fidelity Through Format Conversion

Anthropic prompt caching only hits when the request is a byte-stable prefix extension of a previous request, up to a `cache_control` breakpoint that sits at the same position. The Anthropic-endpoint conversion (`AnthropicFormat.to_openai_params` → `Adapters.Anthropic.build_anthropic_request`) must therefore obey two invariants:

1. **Breakpoints stay on their blocks.** Never join multi-block content into one string when a block carries `cache_control`: the breakpoint slides to the end of the joined text, pulling any volatile tail (env info, the advisor question, mid-message reminders) inside the cached segment — every request then rewrites the whole tail (`cache_read` pins at the last stable breakpoint, `cache_creation` grows monotonically; this cost ~330k extra cache-write tokens per Claude Code session before it was fixed). Multi-block user/system content is carried as a parts array with per-part `cache_control`; the Anthropic adapter rebuilds blocks 1:1.
2. **Representation depends only on content, never on cache_control.** Clients move breakpoints between turns; if cc presence changed a message's rendering (string vs parts), an unchanged message's bytes would change and bust the cache at that point. Single text block → string; anything else → parts. This rule must survive refactors.

OpenAI-family providers cache by prefix automatically and need no `cache_control`; `Adapter.sanitize_messages` flattens parts arrays (user/tool/system) to plain strings for them, dropping the embedded cc keys.

When touching the conversion, keep the "cache breakpoints survive the full request round-trip" seam tests green (`anthropic_format_test.exs`).

## LLM Provider Reasoning Effort Handling

Reasoning/thinking controls are **not standardized** across LLM providers. The proxy stores a canonical `reasoning_effort` level on each `RoutingStep` and translates it into the provider-native field when building the upstream request.

### The Contract

Every adapter's request builder **must** call `Adapter.inject_reasoning_effort(body, step.reasoning_effort, format)` with the format that matches the upstream API:

* `:openai` — top-level `reasoning_effort`
* `:responses` — `reasoning.effort` (OpenAI Responses API / Codex backend)
* `:anthropic` — `thinking.type = "enabled"` plus a `budget_tokens` value, with `max_tokens` bumped to exceed the budget
* `:gemini` — `generationConfig.thinkingConfig.thinkingBudget`
* `:on_off` — `thinking.type = "enabled"` or `"disabled"` (DeepSeek, z.ai, Moonshot-style providers)
* `:none` — no injection

The helper respects **client precedence**: if the incoming request already contains the provider-native field, the step default is not applied. A `reasoning_effort` of `nil` or `""` means "leave the request untouched".

### Canonical Levels

The UI and schema support these effort levels:

```
none, minimal, low, medium, high, xhigh, max
```

The helper maps them to provider-specific values:

| Level | Anthropic budget | Gemini budget | OpenAI/xAI/Responses |
|-------|------------------|---------------|----------------------|
| none  | omit             | 0             | omit                 |
| minimal | 1,024          | 0             | "minimal"            |
| low   | 4,096            | 2,048         | "low"                |
| medium| 10,000           | 8,192         | "medium"             |
| high  | 16,000           | 16,384        | "high"               |
| xhigh | 24,000           | 24,576        | "high"               |
| max   | 32,000           | 24,576        | "high"               |

### Adding or Modifying an Adapter

When integrating a new provider or changing how an existing one handles reasoning:

1. **Identify the native field** (`reasoning_effort`, `thinking`, `reasoning.effort`, `thinkingConfig.thinkingBudget`, etc.).
2. **Pick the appropriate format** and call `Adapter.inject_reasoning_effort/3` in the adapter's request builder.
3. **Document the mapping** in the table above if it differs from existing formats.
4. **Test the seam** — write a test that builds the adapter's request body with a step that has `reasoning_effort` set and assert the provider-native field appears. Also assert that a client-provided value is preserved.

## Releases and Deployment

This application is deployed using Elixir releases with **hot upgrades** — code is updated without restarting the BEAM VM or dropping in-flight requests.

### Release Configuration

Releases are configured in `mix.exs` under the `releases:` key:
- Unix-only executables
- Stripped BEAM files for smaller size
- Full ERTS included for portability

### Build Process

1. Push to `main` triggers `.github/workflows/build-release.yml`
2. Version is auto-bumped (patch level) via `.github/scripts/bump-version.sh`, which also **auto-generates `appup.ex`** from the git diff
3. GitHub Actions builds the release with `MIX_ENV=prod mix release`
4. If a previous release exists, an upgrade tarball is also built with `mix release --upgrade`
5. Release is published as a GitHub Release with attached tarball

### Deployment Process

1. `.github/workflows/deploy.yml` triggers on release publication
2. Downloads the release tarball from GitHub Releases
3. Uses Tailscale VPN to connect to the Hetzner VPS
4. SCPs tarball and `infra/deploy-server.sh` to the server
5. Executes deploy script which performs a **hot upgrade** via Castle (`bin/dodo_router unpack/install/commit <version>`)

### Server Infrastructure

- **Systemd user service**: `infra/dodo-router.service` runs the release at `~/dodorouter/current/`
- **Docker Compose**: Only runs Postgres (`infra/docker-compose.yml`). The app itself runs natively via user-level systemd.
- **Environment variables**: Loaded from `~/dodorouter/.env`

### Hot Upgrade Requirements

For hot upgrades to work correctly:

1. **Stateful processes must implement `code_change/3`**
   - `DodoRouter.Activity` — preserves in-flight request counts
   - `DodoRouter.ShutdownListener` — preserves shutdown flag
   - Any new stateful GenServers must include `code_change/3`

2. **Database migrations must be backward-compatible**
   - **CRITICAL**: Migrations run **before** the new code deploys. The old code is still running when migrations execute.
   - The deploy workflow automatically runs migrations before deploying. **Always** follow these rules when creating migrations:
     - **Creating migrations**: **Always** generate with `mix ecto.gen.migration <name>` — **never** hand-write version numbers. Ecto tracks applied migrations by version integer alone, so two files that ever share a version silently skip each other in any environment where that version is already recorded (this broke the 0.1.86 deploy). `mix precommit` runs `migrations.check_versions` to catch duplicates.
     - **Migrations must be self-contained Ecto.Migration DSL** — never call application modules. The deploy extracts the new release's migration `.exs` files and runs them through the **currently installed (old) release** before upgrading, so application code from the new release is not available to them.
     - **Adding columns**: Add as `null: true` (no `default` on existing rows). The old code won't know about the new column, so it must not fail on insert.
     - **Adding tables**: Safe — old code won't reference them.
     - **Adding indexes**: Use `create_index/3` with `concurrently: true` to avoid locking tables.
     - **Renaming columns**: **Never** rename during a hot upgrade. Old code will reference the old name and crash. Do it in two deploys: add new column → migrate data → deploy code → remove old column.
     - **Removing columns**: **Never** drop columns during a hot upgrade. Old code may still reference them. Mark as deprecated first, remove in a later deploy.
     - **Removing tables**: **Never** drop tables during a hot upgrade. Old code may still query them.
     - **Changing constraints**: **Never** add `NOT NULL` to existing columns during a hot upgrade. Old code may insert rows without that field. Add as nullable, then enforce in application code, then make NOT NULL in a later deploy.
   - **Migration failures**: If the deploy workflow reports "Migrations already up" but the app crashes with missing columns, the `schema_migrations` table is out of sync with the actual schema. Fix by manually running the migration SQL or resetting the migration record.
   - If a migration cannot be made backward-compatible, the deploy must be a **full restart** (not hot upgrade). Flag this in the PR description.

3. **HEEx templates must be backward-compatible**
   - Old LiveView processes keep running with old templates during a hot upgrade.
   - **Always** make template changes additive or compatible:
     - **Adding new elements**: Safe — old processes just won't show them.
     - **Adding CSS classes**: Safe if old CSS handles them gracefully.
     - **Removing elements**: Risky — old CSS/JS may break without them. Do in a later deploy.
     - **Changing IDs or data attributes**: Risky — old JS hooks may break. Do in a later deploy.
   - Caddy serves `/assets/*` directly from disk, bypassing Phoenix. The deploy workflow syncs `priv/static` to Caddy's mounted directory after each deploy.
   - **Phoenix memoizes resolved static asset paths per URL** (`Phoenix.Config.cache` is get-or-compute), so digests memoized at cold boot survive hot upgrades — and survive a plain `Endpoint.Supervisor.warmup/1`, whose per-path population is also get-or-compute. Pages keep linking boot-era CSS/JS no matter how many releases hot-upgrade on top. The deploy fixes this after each hot upgrade via `bin/dodo_router rpc 'Phoenix.Config.clear_cache(DodoRouterWeb.Endpoint); Phoenix.Endpoint.Supervisor.warmup(DodoRouterWeb.Endpoint)'` (clear the memos, then re-warm from the current release's manifest).

4. **ERTS version must match**
   - Upgrading Elixir or OTP versions requires a full release (not hot upgrade)
   - The build workflow detects ERTS changes and falls back to full deploy

### Rollback

If a hot upgrade fails, the deploy script automatically restores from backup and restarts the service. Manual rollback with Castle:
```bash
# List releases to see what's available
~/dodorouter/current/bin/dodo_router releases

# Remove failed version
~/dodorouter/current/bin/dodo_router remove <failed_version>

# Restart to boot into previous permanent version
systemctl --user restart dodo-router
```

### Production Commands

```bash
# Check status
systemctl --user status dodo-router

# View logs
journalctl --user -u dodo-router -f

# Remote console
~/dodorouter/current/bin/dodo_router remote

# Run migrations
~/dodorouter/current/dodo_router/bin/dodo_router eval DodoRouter.Release.migrate

# Run seeds
~/dodorouter/current/bin/seed

# Manual restart (if hot upgrade not possible)
systemctl --user restart dodo-router

# Castle release management
~/dodorouter/current/bin/dodo_router releases          # List installed releases
~/dodorouter/current/bin/dodo_router unpack 0.1.8      # Extract release tarball
~/dodorouter/current/bin/dodo_router install 0.1.8     # Install as current version
~/dodorouter/current/bin/dodo_router commit 0.1.8      # Make permanent
~/dodorouter/current/bin/dodo_router remove 0.1.7      # Clean up old version
```

### Elixir Hot Code Upgrades (OTP Release Protocol)

This project uses **Castle** (v0.3.1) to manage hot code upgrades. Castle handles the runtime orchestration — unpacking releases, installing them, and managing the `RELEASES` file. However, you are still responsible for writing `.appup` files that describe how each module transitions between versions.

**Castle's role:**
- Build-time: Integrates via Forecastle to wrap release assembly
- Runtime: Provides `bin/releases`, `bin/unpack`, `bin/install`, `bin/commit` commands
- Generates `sys.config` from `runtime.exs` before boot and during upgrades

**Your responsibility:**

The CI pipeline **auto-generates** `.appup` files via `scripts/generate_appup.exs` during the `bump-version.sh` step. The script detects changed `.ex` and `.html.heex` files and maps them to OTP modules automatically.

**What you must do when modifying stateful processes:**

If your changes touch any GenServer, Agent, or Supervisor, you **MUST** implement `code_change/3` to migrate in-memory state. The auto-generated appup will use `{update, Module, {advanced, []}}` for these, which triggers `code_change/3` during the hot upgrade.

**What you do NOT need to do:**
- Manually edit `appup.ex` — CI generates it automatically
- List changed modules — the script handles this
- Worry about `{load_module}` vs `{update}` — the script distinguishes regular modules from GenServers/Agents

**Important considerations:**
- **Formatting-only changes** (e.g., whitespace, line breaks) may create harmless false positives in the auto-generated appup. Including them with `{load_module}` is safe but unnecessary.
- **Non-standard template paths** — if you add `.html.heex` files outside `components/layouts/` or `controllers/*_html/`, the script may miss them. In this case, add the parent module manually to `appup.ex` before pushing.
- **GenServer state migrations** — If a GenServer's state structure changes (new fields, type changes), implement `code_change/3` with migration logic. If the migration is complex or risky, flag it for a full restart instead of hot upgrade.

**Verify locally (optional):**
```bash
# Preview what the appup will look like for your changes
elixir scripts/generate_appup.exs <old-sha> <new-sha>
```

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:970c3bf2 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.

## Agent Context Profiles

The managed Beads block is task-tracking guidance, not permission to override repository, user, or orchestrator instructions.

- **Conservative (default)**: Use `bd` for task tracking. Do not run git commits, git pushes, or Dolt remote sync unless explicitly asked. At handoff, report changed files, validation, and suggested next commands.
- **Minimal**: Keep tool instruction files as pointers to `bd prime`; use the same conservative git policy unless active instructions say otherwise.
- **Team-maintainer**: Only when the repository explicitly opts in, agents may close beads, run quality gates, commit, and push as part of session close. A current "do not commit" or "do not push" instruction still wins.

## Session Completion

This protocol applies when ending a Beads implementation workflow. It is subordinate to explicit user, repository, and orchestrator instructions.

1. **File issues for remaining work** - Create beads for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **Handle git/sync by active profile**:
   ```bash
   # Conservative/minimal/default: report status and proposed commands; wait for approval.
   git status

   # Team-maintainer opt-in only, unless current instructions forbid it:
   git pull --rebase
   bd dolt push
   git push
   git status
   ```
5. **Hand off** - Summarize changes, validation, issue status, and any blocked sync/commit/push step

**Critical rules:**
- Explicit user or orchestrator instructions override this Beads block.
- Do not commit or push without clear authority from the active profile or the current user request.
- If a required sync or push is blocked, stop and report the exact command and error.
<!-- END BEADS INTEGRATION -->

<!-- BEGIN BEADS CODEX SETUP: generated by bd setup codex -->
## Beads Issue Tracker

Use Beads (`bd`) for durable task tracking in repositories that include it. Use the `beads` skill at `.agents/skills/beads/SKILL.md` (project install) or `~/.agents/skills/beads/SKILL.md` (global install) for Beads workflow guidance, then use the `bd` CLI for issue operations.

### Quick Reference

```bash
bd ready                # Find available work
bd show <id>            # View issue details
bd update <id> --claim  # Claim work
bd close <id>           # Complete work
bd prime                # Refresh Beads context
```

### Rules

- Use `bd` for all task tracking; do not create markdown TODO lists.
- Run `bd prime` when Beads context is missing or stale. Codex 0.129.0+ can load Beads context automatically through native hooks; use `/hooks` to inspect or toggle them.
- Keep persistent project memory in Beads via `bd remember`; do not create ad hoc memory files.

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.
<!-- END BEADS CODEX SETUP -->
