package spacelift

deny contains message if {
  input.spacelift.run.type == "TRACKED"
  not input.spacelift.run.drift_detection
  message := "Railway cron POC is observe-only; tracked applies are disabled."
}

deny contains message if {
  some change in input.terraform.resource_changes
  change.change.actions[_] == "delete"
  message := sprintf("Railway cron POC forbids deletes: %s", [change.address])
}

warn contains message if {
  input.spacelift.run.type == "PROPOSED"
  message := "Railway cron POC validates committed cron config against live Railway metadata before planning."
}
