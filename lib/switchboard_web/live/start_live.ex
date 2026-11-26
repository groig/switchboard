defmodule SwitchboardWeb.StartLive do
  @moduledoc """
  Get started: one guided path from signing in to "my agent just did something useful". Four
  sections, each done or not: connect an agent, link accounts, try some prompts, learn the
  commands. Everything comes from existing records (`Switchboard.Onboarding`): the checklist
  ticks off live from the person's audit rows, and the prompts are personalized in the
  background with their own Plane and Argus data.
  """
  use SwitchboardWeb, :live_view

  alias Switchboard.{Audit, OAuth, Onboarding, Upstreams, Workflows}
  alias SwitchboardWeb.ConnectionsLive

  # "Try these" counts as done once this many prompts were tried.
  @tried_goal 3

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    socket =
      socket
      |> assign(:page_title, gettext("Get started"))
      |> assign(:mcp_url, OAuth.resource())
      |> assign(:samples, :loading)
      |> load()

    socket =
      if connected?(socket) do
        Audit.subscribe_user(scope.user.id)
        start_async(socket, :samples, fn -> Onboarding.samples(scope) end)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    client =
      case params["client"] do
        "codex" -> :codex
        "claude" -> :claude_code
        _ -> socket.assigns[:client] || default_client(socket.assigns.agent)
      end

    {:noreply, assign(socket, :client, client)}
  end

  defp default_client(%{client: name}) when is_binary(name) do
    if String.downcase(name) =~ "codex", do: :codex, else: :claude_code
  end

  defp default_client(_), do: :claude_code

  defp load(socket) do
    scope = socket.assigns.current_scope
    accounts = Onboarding.accounts(scope)
    tried = Onboarding.tried(scope.user)
    agent = Onboarding.agent(scope.user)
    prompts = Onboarding.prompts()
    tried_count = Enum.count(prompts, &Onboarding.done?(&1, tried))
    linked = Enum.count(accounts, &(&1.status == :linked))

    done = %{
      agent: agent != nil,
      accounts: linked == length(accounts),
      prompts: tried_count >= @tried_goal,
      commands: Enum.any?(tried, &String.starts_with?(&1, "workflow:"))
    }

    socket
    |> assign(:accounts, accounts)
    |> assign(:linked, linked)
    |> assign(:tried, tried)
    |> assign(:tried_count, tried_count)
    |> assign(:agent, agent)
    |> assign(:done, done)
    |> assign(:steps_done, Enum.count(done, fn {_k, v} -> v end))
  end

  @impl true
  def handle_async(:samples, {:ok, samples}, socket),
    do: {:noreply, assign(socket, :samples, samples)}

  def handle_async(:samples, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, :samples, %{})}

  @impl true
  def handle_info({:audit_event, _event}, socket), do: {:noreply, load(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:start}>
      <:crumb>{gettext("Get started")}</:crumb>

      <Layouts.page_header
        title={gettext("Get started")}
        lead={
          gettext(
            "Four steps from signing in to your agent doing something useful with your tasks, code, errors, wiki and chat."
          )
        }
      >
        <:actions>
          <div id="steps-progress" class="w-44">
            <div class="mb-1.5 flex justify-between text-xs text-fg-muted tabular-nums">
              <span>{gettext("Progress")}</span>
              <span>{gettext("%{done} of 4 done", done: @steps_done)}</span>
            </div>
            <.progress
              value={@steps_done}
              max={4}
              tone={if(@steps_done == 4, do: "success", else: "accent")}
              label={gettext("Steps done")}
            />
          </div>
        </:actions>
      </Layouts.page_header>

      <div class="space-y-6">
        <.step id="step-agent" number={1} done={@done.agent} title={gettext("Connect your agent")}>
          <:status>
            <%= if @agent do %>
              <span id="agent-done" class="text-sm text-fg-muted">
                {gettext("%{client} called Switchboard", client: @agent.client || gettext("A client"))}
                <.relative_time at={@agent.at} scope={@current_scope} />
              </span>
            <% end %>
          </:status>

          <.tabs id="client-tabs" class="mb-4">
            <:tab id="tab-claude" patch={~p"/start?client=claude"} active={@client == :claude_code}>
              Claude Code
            </:tab>
            <:tab id="tab-codex" patch={~p"/start?client=codex"} active={@client == :codex}>
              Codex
            </:tab>
          </.tabs>

          <p class="mb-2 text-sm text-fg-muted">
            <%= if @client == :codex do %>
              {gettext("Run this in a terminal. Codex opens your browser right away to sign in.")}
            <% else %>
              {gettext(
                "Run these in a terminal (the login needs an interactive one). Your browser opens to sign in with Forgejo."
              )}
            <% end %>
          </p>
          <.command_box id="connect-commands" commands={connect_commands(@client, @mcp_url)} />

          <div class="mt-4 flex flex-wrap items-center gap-x-3 gap-y-2 text-sm">
            <span class="text-fg-muted">{gettext("Check it works: ask your agent")}</span>
            <.copy_chip id="check-prompt" text={gettext("Who am I in Switchboard?")} />
          </div>
        </.step>

        <.step
          id="step-accounts"
          number={2}
          done={@done.accounts}
          title={gettext("Link your accounts")}
        >
          <:status>
            <span id="accounts-count" class="text-sm text-fg-muted tabular-nums">
              {gettext("%{linked} of %{total} linked",
                linked: @linked,
                total: length(@accounts)
              )}
            </span>
          </:status>

          <p class="mb-3 text-sm text-fg-muted">
            {gettext(
              "Switchboard calls each system as you, with your own key. Create the key in the system, then paste it on Connections."
            )}
          </p>
          <ul id="accounts" class="divide-y divide-border rounded-lg border border-border">
            <.account_row :for={account <- @accounts} account={account} />
          </ul>
        </.step>

        <.step id="step-prompts" number={3} done={@done.prompts} title={gettext("Try these")}>
          <:status>
            <span id="tried-count" class="text-sm text-fg-muted tabular-nums">
              {gettext("%{tried} of %{total} tried",
                tried: @tried_count,
                total: length(Onboarding.prompts())
              )}
            </span>
          </:status>

          <p class="mb-4 text-sm text-fg-muted">
            {gettext(
              "Copy one into your agent. Each one ticks off here as soon as your agent has used it."
            )}
          </p>
          <div class="grid gap-5 lg:grid-cols-3">
            <section :for={{group, label} <- groups()} id={"prompts-#{group}"}>
              <h3 class="mb-2 text-xs font-medium tracking-wide text-fg-subtle uppercase">
                {label}
              </h3>
              <ul class="space-y-1.5">
                <.prompt_row
                  :for={prompt <- Enum.filter(Onboarding.prompts(), &(&1.group == group))}
                  prompt={prompt}
                  done={Onboarding.done?(prompt, @tried)}
                  missing={Onboarding.missing(prompt, @accounts)}
                  samples={@samples}
                />
              </ul>
            </section>
          </div>
        </.step>

        <.step id="step-commands" number={4} done={@done.commands} title={gettext("Commands")}>
          <:status>
            <span class="text-sm text-fg-muted">
              {gettext("Team workflows, ready-made")}
            </span>
          </:status>

          <p class="mb-3 text-sm text-fg-muted">
            <%= if @client == :codex do %>
              {gettext(
                "Codex has no slash commands for these: ask in your own words and the agent runs them."
              )}
            <% else %>
              {gettext(
                "In Claude Code, type / and the command's name. In Codex, ask in your own words."
              )}
            <% end %>
            {gettext("Commands only read; your agent asks before it posts or changes anything.")}
          </p>
          <div class="overflow-x-auto rounded-lg border border-border">
            <table id="commands" class="w-full text-sm">
              <thead class="bg-inset text-left text-xs text-fg-subtle">
                <tr>
                  <th class="px-3 py-2 font-medium">{gettext("Command")}</th>
                  <th class="px-3 py-2 font-medium">{gettext("What for")}</th>
                  <th class="px-3 py-2 font-medium">Claude Code</th>
                  <th class="px-3 py-2 font-medium">Codex</th>
                </tr>
              </thead>
              <tbody class="divide-y divide-border">
                <tr :for={cmd <- commands()} id={"command-#{cmd.name}"} class="align-top">
                  <td class="px-3 py-2.5">
                    <span class="flex items-center gap-1.5">
                      <.icon
                        :if={MapSet.member?(@tried, "workflow:" <> cmd.name)}
                        name="hero-check-circle-mini"
                        class="size-4 text-success-fg"
                      />
                      <code class="font-mono text-xs font-medium text-fg">{cmd.name}</code>
                    </span>
                  </td>
                  <td class="min-w-48 px-3 py-2.5 text-fg-muted">{cmd.purpose}</td>
                  <td class="px-3 py-2.5">
                    <code class="font-mono text-xs whitespace-nowrap text-fg">{cmd.claude}</code>
                  </td>
                  <td class="min-w-44 px-3 py-2.5 text-fg-muted">“{cmd.codex}”</td>
                </tr>
              </tbody>
            </table>
          </div>
        </.step>
      </div>
    </Layouts.app>
    """
  end

  ## Components

  attr :id, :string, required: true
  attr :number, :integer, required: true
  attr :title, :string, required: true
  attr :done, :boolean, required: true
  slot :status
  slot :inner_block, required: true

  defp step(assigns) do
    ~H"""
    <section
      id={@id}
      data-done={to_string(@done)}
      class="rounded-xl border border-border bg-surface shadow-xs"
    >
      <header class="flex flex-wrap items-center gap-x-3 gap-y-1 border-b border-border px-4 py-3">
        <span class={[
          "flex size-7 shrink-0 items-center justify-center rounded-full text-sm font-semibold tabular-nums",
          "transition-colors duration-(--duration-base)",
          if(@done, do: "bg-success-soft text-success-fg", else: "bg-inset text-fg-muted")
        ]}>
          <%= if @done do %>
            <.icon name="hero-check-mini" class="size-4" />
          <% else %>
            {@number}
          <% end %>
        </span>
        <h2 class="text-md font-semibold text-fg">{@title}</h2>
        <.badge :if={@done} tone="success" id={"#{@id}-done"}>{gettext("Done")}</.badge>
        <div :if={@status != []} class="ml-auto">{render_slot(@status)}</div>
      </header>
      <div class="p-4">{render_slot(@inner_block)}</div>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :commands, :list, required: true

  defp command_box(assigns) do
    ~H"""
    <div
      id={@id}
      class="divide-y divide-border overflow-hidden rounded-lg border border-border bg-inset font-mono text-xs"
    >
      <div :for={{cmd, i} <- Enum.with_index(@commands)} class="flex items-center gap-2 px-3 py-2">
        <code id={"#{@id}-#{i}"} class="min-w-0 flex-1 overflow-x-auto whitespace-nowrap text-fg">
          {cmd}
        </code>
        <.icon_button
          id={"#{@id}-copy-#{i}"}
          icon="hero-clipboard-document-mini"
          label={gettext("Copy")}
          phx-click={copy(cmd, gettext("Copied"))}
        />
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :text, :string, required: true

  defp copy_chip(assigns) do
    ~H"""
    <button
      type="button"
      id={@id}
      phx-click={copy(@text, gettext("Copied"))}
      class={[
        "inline-flex cursor-pointer items-center gap-1.5 rounded-md border border-border bg-inset px-2 py-1 text-sm text-fg",
        "transition-[background-color,transform] duration-(--duration-fast) hover:bg-hover active:scale-[0.98]"
      ]}
    >
      “{@text}” <.icon name="hero-clipboard-document-micro" class="size-3.5 text-fg-subtle" />
    </button>
    """
  end

  attr :account, :map, required: true

  defp account_row(assigns) do
    assigns =
      assign(assigns,
        system: assigns.account.system,
        mod: elem(Upstreams.fetch(assigns.account.system), 1),
        workflows: Onboarding.workflows_using(assigns.account.system)
      )

    ~H"""
    <li
      id={"account-#{@system}"}
      data-status={@account.status}
      class="flex flex-col gap-3 px-4 py-3 sm:flex-row sm:items-center"
    >
      <div class="flex min-w-0 flex-1 items-start gap-3">
        <div class="flex size-8 shrink-0 items-center justify-center rounded-lg bg-inset text-fg-muted">
          <.icon name={ConnectionsLive.system_icon(@system)} class="size-4" />
        </div>
        <div class="min-w-0">
          <div class="flex flex-wrap items-center gap-2">
            <span class="font-medium text-fg">{@account.label}</span>
            <%= case @account.status do %>
              <% :linked -> %>
                <.badge tone="success" dot>{gettext("Linked")}</.badge>
              <% :error -> %>
                <.badge tone="danger" dot>{gettext("Needs attention")}</.badge>
              <% :missing -> %>
                <.badge>{gettext("Not linked")}</.badge>
            <% end %>
          </div>
          <p class="mt-0.5 text-sm text-fg-muted">
            {Gettext.gettext(SwitchboardWeb.Gettext, Onboarding.unlocks(@system))}
          </p>
          <div :if={@workflows != []} class="mt-1 flex flex-wrap gap-1">
            <code
              :for={name <- @workflows}
              class="rounded-sm bg-inset px-1 py-px font-mono text-2xs text-fg-muted"
            >
              {name}
            </code>
          </div>
          <p :if={@account.status != :linked} class="mt-1 text-xs text-fg-subtle">
            {@mod.permissions()}
          </p>
        </div>
      </div>
      <div class="flex shrink-0 items-center gap-2">
        <%= cond do %>
          <% @system == "forgejo" and @account.status == :linked -> %>
            <span class="text-xs text-fg-subtle">{gettext("From your sign-in")}</span>
          <% @system == "forgejo" -> %>
            <span class="text-xs text-fg-subtle">{gettext("Sign out and in again")}</span>
          <% true -> %>
            <.button
              :if={@account.status != :linked and @mod.key_url()}
              id={"key-link-#{@system}"}
              size="sm"
              href={@mod.key_url()}
              target="_blank"
              rel="noopener noreferrer"
              icon="hero-arrow-top-right-on-square-mini"
            >
              {gettext("Create a key")}
            </.button>
            <.button
              id={"link-#{@system}"}
              size="sm"
              variant={if(@account.status == :linked, do: "ghost", else: "primary")}
              navigate={~p"/connections" <> "#connection-#{@system}"}
            >
              {if(@account.status == :linked, do: gettext("Manage"), else: gettext("Link"))}
            </.button>
        <% end %>
      </div>
    </li>
    """
  end

  attr :prompt, :map, required: true
  attr :done, :boolean, required: true
  attr :missing, :list, required: true
  attr :samples, :any, required: true

  defp prompt_row(assigns) do
    # Placeholders stay in the template; fill/2 puts in the person's task and error.
    template =
      Gettext.gettext(SwitchboardWeb.Gettext, assigns.prompt.text,
        task: "%{task}",
        error: "%{error}"
      )

    needs_sample? = template =~ "%{task}" or template =~ "%{error}"

    assigns =
      assign(assigns,
        loading: needs_sample? and assigns.samples == :loading,
        text:
          Onboarding.fill(template, if(is_map(assigns.samples), do: assigns.samples, else: %{})),
        ready: assigns.missing == []
      )

    ~H"""
    <li
      id={"prompt-#{@prompt.id}"}
      data-done={to_string(@done)}
      data-ready={to_string(@ready)}
      class={[
        "group flex items-start gap-2 rounded-lg border border-border px-2.5 py-2 transition-colors duration-(--duration-base)",
        if(@done, do: "bg-success-soft/40", else: "bg-surface"),
        !@ready && "opacity-60"
      ]}
    >
      <.icon
        name={if(@done, do: "hero-check-circle-mini", else: "hero-chat-bubble-left-mini")}
        class={["mt-0.5 size-4 shrink-0", if(@done, do: "text-success-fg", else: "text-fg-subtle")]}
      />
      <div class="min-w-0 flex-1">
        <%= if @loading do %>
          <.skeleton class="mt-0.5 h-4 w-40" id={"prompt-#{@prompt.id}-loading"} />
        <% else %>
          <p class="text-sm text-fg" id={"prompt-#{@prompt.id}-text"}>{@text}</p>
        <% end %>
        <p :if={!@ready} class="mt-0.5 text-xs text-fg-subtle" id={"prompt-#{@prompt.id}-hint"}>
          <.link
            navigate={~p"/connections" <> "#connection-#{hd(@missing)}"}
            class="font-medium text-accent-fg hover:underline"
          >
            {gettext("Link %{system} to try this", system: label(hd(@missing)))}
          </.link>
        </p>
      </div>
      <.icon_button
        :if={@ready and not @loading}
        id={"prompt-#{@prompt.id}-copy"}
        icon="hero-clipboard-document-mini"
        label={gettext("Copy")}
        size="xs"
        variant="ghost"
        phx-click={copy(@text, gettext("Copied"))}
      />
    </li>
    """
  end

  ## Data

  defp groups do
    [
      look: gettext("Look around"),
      work: gettext("Work"),
      wow: gettext("Wow")
    ]
  end

  @doc false
  # The Commands section, generated from the workflow registry.
  def commands do
    for mod <- Workflows.all() do
      args =
        Enum.map_join(mod.arguments(), "", fn a ->
          " " <> (mod.example().args[a.name] || "<#{a.name}>")
        end)

      %{
        name: mod.name(),
        purpose: Gettext.gettext(SwitchboardWeb.Gettext, mod.purpose()),
        claude: "/mcp__switchboard__#{mod.name()}#{args}",
        codex: Gettext.gettext(SwitchboardWeb.Gettext, mod.example().says)
      }
    end
  end

  defp connect_commands(:codex, url), do: ["codex mcp add switchboard --url #{url}"]

  defp connect_commands(_claude, url) do
    [
      "claude mcp add --transport http switchboard #{url}",
      "claude mcp login switchboard"
    ]
  end

  defp label(system) do
    case Upstreams.fetch(system) do
      {:ok, mod} -> mod.label()
      :error -> system
    end
  end
end
