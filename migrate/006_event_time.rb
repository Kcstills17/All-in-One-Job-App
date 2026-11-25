# An optional time of day on a timeline step ("14:30"), for interviews. Like the stage and date,
# it isn't encrypted: it says when, not what or with whom.
Sequel.migration do
  change do
    add_column :application_events, :at, String, size: 5
  end
end
