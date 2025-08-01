# Couple rules:
#
# 1. This file should contain all supported application environment variables,
# even if they are overridden in `runtime.exs`, because it's the main source of
# truth and self-documentation.
#
# 2. The configurations here should be as close to `dev` environment as possible,
# to prevent having too many overrides in other files.
import Config

###############################
##### Domain ##################
###############################

config :domain, ecto_repos: [Domain.Repo]
config :domain, generators: [binary_id: true, context_app: :domain]

config :domain, sql_sandbox: false

# Don't run manual migrations by default
config :domain, run_manual_migrations: false

config :domain, Domain.Repo,
  hostname: "localhost",
  username: "postgres",
  password: "postgres",
  database: "firezone_dev",
  show_sensitive_data_on_connection_error: true,
  pool_size: :erlang.system_info(:logical_processors_available) * 2,
  queue_target: 500,
  queue_interval: 1000,
  migration_timestamps: [type: :timestamptz],
  migration_lock: :pg_advisory_lock,
  start_apps_before_migration: [:ssl, :logger_json]

config :domain, Domain.ChangeLogs.ReplicationConnection,
  replication_slot_name: "change_logs_slot",
  publication_name: "change_logs_publication",
  enabled: true,
  connection_opts: [
    hostname: "localhost",
    port: 5432,
    ssl: false,
    ssl_opts: [],
    parameters: [],
    username: "postgres",
    database: "firezone_dev",
    password: "postgres"
  ],
  # When changing these, make sure to also:
  #   1. Make appropriate changes to `Domain.ChangeLogs.ReplicationConnection`
  #   2. Add tests and test WAL locally
  table_subscriptions: ~w[
    accounts
    actor_group_memberships
    actor_groups
    actors
    auth_identities
    auth_providers
    clients
    gateway_groups
    gateways
    policies
    resource_connections
    resources
    tokens
  ],
  # Allow up to 5 minutes of processing lag before alerting. This needs to be able to survive
  # deploys without alerting.
  warning_threshold: :timer.minutes(5),

  # We almost never want to bypass changelog inserts
  error_threshold: :timer.hours(30 * 24),

  # Flush change logs data at least every 30 seconds
  flush_interval: :timer.seconds(30),

  # We want to flush at most 500 change logs at a time
  flush_buffer_size: 500

config :domain, Domain.Events.ReplicationConnection,
  replication_slot_name: "events_slot",
  publication_name: "events_publication",
  enabled: true,
  connection_opts: [
    hostname: "localhost",
    port: 5432,
    ssl: false,
    ssl_opts: [],
    parameters: [],
    username: "postgres",
    database: "firezone_dev",
    password: "postgres"
  ],
  # When changing these, make sure to also:
  #   1. Make appropriate changes to `Domain.Events.ReplicationConnection`
  #   2. Add an appropriate `Domain.Events.Hooks` module
  #   3. Add tests and test WAL locally
  table_subscriptions: ~w[
    accounts
    actor_group_memberships
    clients
    flows
    gateways
    gateway_groups
    policies
    resource_connections
    resources
    tokens
  ],
  # Allow up to 60 seconds of lag before alerting
  warning_threshold: :timer.seconds(60),

  # Allow up to 30 minutes of lag before bypassing hooks
  error_threshold: :timer.minutes(30),

  # Disable flush
  flush_interval: 0,
  flush_buffer_size: 0

config :domain, Domain.Tokens,
  key_base: "5OVYJ83AcoQcPmdKNksuBhJFBhjHD1uUa9mDOHV/6EIdBQ6pXksIhkVeWIzFk5S2",
  salt: "t01wa0K4lUd7mKa0HAtZdE+jFOPDDej2"

config :domain, Domain.Telemetry, metrics_reporter: nil, healthz_port: 4000

config :domain, Domain.Analytics,
  mixpanel_token: nil,
  hubspot_workspace_id: nil

config :domain, Domain.Auth.Adapters.GoogleWorkspace.APIClient,
  endpoint: "https://admin.googleapis.com",
  token_endpoint: "https://oauth2.googleapis.com",
  finch_transport_opts: []

config :domain, Domain.Auth.Adapters.MicrosoftEntra.APIClient,
  endpoint: "https://graph.microsoft.com",
  finch_transport_opts: []

config :domain, Domain.Auth.Adapters.Okta.APIClient, finch_transport_opts: []

config :domain, Domain.Billing.Stripe.APIClient,
  endpoint: "https://api.stripe.com",
  finch_transport_opts: [],
  retry_config: [
    max_retries: 3,
    base_delay_ms: 1000,
    max_delay_ms: 10_000
  ]

config :domain, Domain.Billing,
  enabled: true,
  secret_key: "sk_test_1111",
  webhook_signing_secret: "whsec_test_1111",
  default_price_id: "price_1OkUIcADeNU9NGxvTNA4PPq6"

config :domain, platform_adapter: nil

config :domain, Domain.GoogleCloudPlatform,
  metadata_endpoint_url: "http://metadata.google.internal/computeMetadata/v1",
  aggregated_list_endpoint_url:
    "https://compute.googleapis.com/compute/v1/projects/${project_id}/aggregated/instances",
  cloud_metrics_endpoint_url:
    "https://monitoring.googleapis.com/v3/projects/${project_id}/timeSeries",
  sign_endpoint_url: "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/",
  cloud_storage_url: "https://storage.googleapis.com"

config :domain, Domain.ComponentVersions,
  firezone_releases_url: "https://www.firezone.dev/api/releases",
  fetch_from_url: true,
  versions: [
    apple: "1.3.8",
    android: "1.3.6",
    gateway: "1.4.0",
    gui: "1.3.11",
    headless: "1.3.5"
  ]

config :domain, Domain.Cluster,
  adapter: nil,
  adapter_config: []

config :domain, Domain.Instrumentation,
  client_logs_enabled: true,
  client_logs_bucket: "logs"

config :domain, :enabled_features,
  idp_sync: true,
  traffic_filters: true,
  sign_up: true,
  self_hosted_relays: true,
  policy_conditions: true,
  multi_site_resources: true,
  rest_api: true,
  internet_resource: true

config :domain, sign_up_whitelisted_domains: []

config :domain, docker_registry: "us-east1-docker.pkg.dev/firezone-staging/firezone"

config :domain, outbound_email_adapter_configured?: false

config :domain, web_external_url: "http://localhost:13000"

###############################
##### Web #####################
###############################

config :web, ecto_repos: [Domain.Repo]
config :web, generators: [binary_id: true, context_app: :domain]
config :web, client_handler: "firezone-fd0020211111://"

config :web, Web.Endpoint,
  url: [
    scheme: "http",
    host: "localhost",
    port: 13_000,
    path: nil
  ],
  render_errors: [
    formats: [
      html: Web.ErrorHTML,
      json: Web.ErrorJSON,
      xml: Web.ErrorXML
    ],
    layout: false
  ],
  pubsub_server: Domain.PubSub,
  secret_key_base: "5OVYJ83AcoQcPmdKNksuBhJFBhjHD1uUa9mDOHV/6EIdBQ6pXksIhkVeWIzFk5SD",
  live_view: [
    signing_salt: "t01wa0K4lUd7mKa0HAtZdE+jFOPDDejX"
  ]

config :web,
  api_external_url: "http://localhost:13001"

config :web,
  cookie_secure: false,
  cookie_signing_salt: "WjllcThpb2Y=",
  cookie_encryption_salt: "M0EzM0R6NEMyaw=="

config :web,
  external_trusted_proxies: [],
  private_clients: [%{__struct__: Postgrex.INET, address: {172, 28, 0, 0}, netmask: 16}]

config :web, Web.Plugs.SecureHeaders,
  csp_policy: [
    "default-src 'self' 'nonce-${nonce}' https://api-js.mixpanel.com",
    "img-src 'self' data: https://www.gravatar.com https://track.hubspot.com",
    "style-src 'self' 'unsafe-inline'",
    "script-src 'self' 'unsafe-inline' https://cdn.mxpnl.com https://*.hs-analytics.net"
  ]

config :web, api_url_override: "ws://localhost:13001/"

###############################
##### API #####################
###############################

config :api, ecto_repos: [Domain.Repo]
config :api, generators: [binary_id: true, context_app: :domain]

config :api, API.Endpoint,
  url: [
    scheme: "http",
    host: "localhost",
    port: 13_001,
    path: nil
  ],
  render_errors: [
    formats: [json: API.ErrorView],
    layout: false
  ],
  secret_key_base: "5OVYJ83AcoQcPmdKNksuBhJFBhjHD1uUa9mDOHV/6EIdBQ6pXksIhkVeWIzFk5SD",
  pubsub_server: Domain.PubSub

config :api,
  cookie_secure: false,
  cookie_signing_salt: "WjllcThpb2Y=",
  cookie_encryption_salt: "M0EzM0R6NEMyaw=="

config :api,
  external_trusted_proxies: [],
  private_clients: [%{__struct__: Postgrex.INET, address: {172, 28, 0, 0}, netmask: 16}],
  relays_presence_debounce_timeout_ms: 3_000

config :api, API.RateLimit,
  refill_rate: 10,
  capacity: 200

###############################
##### Third-party configs #####
###############################

config :domain,
  http_client_ssl_opts: []

config :openid_connect,
  finch_transport_opts: []

config :ex_cldr,
  default_locale: "en"

config :mime, :types, %{
  "application/xml" => ["xml"]
}

config :opentelemetry,
  span_processor: :batch,
  traces_exporter: :none

config :logger, level: String.to_atom(System.get_env("LOG_LEVEL", "info"))

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: :all

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

config :swoosh, :api_client, Swoosh.ApiClient.Finch

config :domain, Domain.Mailer,
  adapter: Domain.Mailer.NoopAdapter,
  from_email: "test@firez.one"

config :esbuild,
  version: "0.25.3",
  web: [
    args: [
      "js/app.js",
      "--bundle",
      "--loader:.woff2=file",
      "--loader:.woff=file",
      "--target=es2017",
      "--outdir=../priv/static/assets",
      "--external:/fonts/*",
      "--external:/images/*"
    ],
    cd: Path.expand("../apps/web/assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "3.4.17",
  web: [
    args: [
      "--config=tailwind.config.js",
      "--input=css/main.css",
      "--output=../priv/static/assets/main.css"
    ],
    cd: Path.expand("../apps/web/assets", __DIR__)
  ]

config :workos, WorkOS.Client,
  api_key: "sk_example_123456789",
  client_id: "client_123456789",
  baseurl: "https://api.workos.com"

# Base Sentry config
config :sentry,
  before_send: {Domain.Telemetry.Sentry, :before_send},
  # disable Sentry by default, enable in runtime.exs
  dsn: nil,
  environment_name: :unknown,
  enable_source_code_context: true,
  root_source_code_paths: [
    Path.join(File.cwd!(), "apps/domain"),
    Path.join(File.cwd!(), "apps/web"),
    Path.join(File.cwd!(), "apps/api")
  ]

config :logger_json, encoder: JSON

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{Mix.env()}.exs"
