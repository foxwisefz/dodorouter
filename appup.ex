# Appup file for DodoRouter
# This describes how to upgrade the application between versions
# Castle's :appup compiler reads this and copies it into the release ebin directory
# Format: {NewVsn, [{OldVsn, [Instructions]}], [{OldVsn, [Instructions]}]}
#
# Instructions:
#   {load_module, Module} - reload a changed module
#   {update, Module, {advanced, []}} - update a GenServer/Agent and call code_change/3
#   {add_module, Module} - add a new module
#   {delete_module, Module} - remove a deleted module

{
  ~c"0.1.66",
  [
    {~c"0.1.65",
     [
       {load_module, DodoRouter.Logs},
       {load_module, DodoRouter.Routers.Router},
       {load_module, DodoRouter.Upgrade},
       {load_module, DodoRouterWeb.Layouts},
       {load_module, DodoRouterWeb.AnthropicProxyController},
       {load_module, DodoRouterWeb.ProxyController},
       {load_module, DodoRouterWeb.ResponsesProxyController},
       {load_module, DodoRouterWeb.RouterLive.FormComponent},
       {load_module, DodoRouterWeb.RouterLive.Show},
       {load_module, DodoRouterWeb.SessionLive.Show}
     ]}
  ],
  [
    {~c"0.1.65",
     [
       {load_module, DodoRouter.Logs},
       {load_module, DodoRouter.Routers.Router},
       {load_module, DodoRouter.Upgrade},
       {load_module, DodoRouterWeb.Layouts},
       {load_module, DodoRouterWeb.AnthropicProxyController},
       {load_module, DodoRouterWeb.ProxyController},
       {load_module, DodoRouterWeb.ResponsesProxyController},
       {load_module, DodoRouterWeb.RouterLive.FormComponent},
       {load_module, DodoRouterWeb.RouterLive.Show},
       {load_module, DodoRouterWeb.SessionLive.Show}
     ]}
  ]
}
