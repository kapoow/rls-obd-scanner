-- Load only this add-on's route registration. RLS and the reference mods are
-- never modified or replaced.
core_jobsystem.create(function(job)
  job.sleep(0.35)
  if not extensions.isExtensionLoaded("rlsObd_routes") then
    extensions.load("rlsObd_routes")
  end
  if extensions.isExtensionLoaded("rlsObd_routes") then
    setExtensionUnloadMode("rlsObd_routes", "manual")
  end
end)
