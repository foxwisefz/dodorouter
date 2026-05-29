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
  ~c"0.1.29",
  [
    {~c"0.1.28", [
      {:load_module, DodoRouter.Upgrade}
    ]}
  ],
  [
    {~c"0.1.28", [
      {:load_module, DodoRouter.Upgrade}
    ]}
  ]
}
