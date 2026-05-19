# Appup file for DodoRouter
# This describes how to upgrade the application between versions
# See: https://hexdocs.pm/castle/readme.html#the-appup-compiler

# Example format:
# {
#   ~c"0.1.2",
#   [
#     {~c"0.1.1", [
#       {:update, MyApp.Server, {:advanced, []}}
#     ]}
#   ],
#   [
#     {~c"0.1.1", [
#       {:update, MyApp.Server, {:advanced, []}}
#     ]}
#   ]
# }

# For now, we use a simple upgrade that just reloads changed modules
# Castle will auto-generate this based on git diffs in the future

{
  ~c"0.1.8",
  [
    {~c"0.1.7", [
      {:update, DodoRouter.Activity, {:advanced, []}},
      {:update, DodoRouter.ShutdownListener, {:advanced, []}}
    ]}
  ],
  [
    {~c"0.1.7", [
      {:update, DodoRouter.Activity, {:advanced, []}},
      {:update, DodoRouter.ShutdownListener, {:advanced, []}}
    ]}
  ]
}
