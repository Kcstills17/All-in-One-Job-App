# "Saved": a job you mean to apply to. It comes before Applied and keeps the lead out of the
# application stats until you apply.
Sequel.migration do
  before = ["Applied", "Followed Up", "Recruiter Screen", "Hiring Manager", "Technical Interview", "Take-home",
            "Final Round", "Work Trial", "Offer", "Accepted", "Rejected", "Ghosted", "Withdrawn"]

  up do
    alter_table(:application_events) do
      drop_constraint :valid_stage
      add_constraint(:valid_stage, stage: ["Saved", *before])
    end
  end

  down do
    from(:application_events).where(stage: "Saved").delete
    alter_table(:application_events) do
      drop_constraint :valid_stage
      add_constraint(:valid_stage, stage: before)
    end
  end
end
