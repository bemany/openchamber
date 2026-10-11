## ADDED Requirements

### Requirement: Three outcomes per turn

For a turn that qualifies for session assist, the generated suggestion part
SHALL be exactly one of: a continuation suggestion (one message), a set of
reply options (2 to 3 messages), or nothing. A continuation and options SHALL
NOT be stored together.

#### Scenario: Unfinished requested work
- **WHEN** the latest answer stopped part-way through work the user requested
  and the agent can continue it itself
- **THEN** the payload contains a non-empty `suggestion` and no `options`

#### Scenario: Agent waits for a short decision
- **WHEN** the latest answer ends by asking the user to choose, approve, or
  answer a question that a few words can settle
- **THEN** the payload contains `options` with 2 or 3 distinct, non-empty
  replies in the user's voice addressed to the agent, and an empty `suggestion`

#### Scenario: Work is finished
- **WHEN** the latest request is satisfied, including an answer that closes
  with a completion status line
- **THEN** the payload contains neither `suggestion` nor `options`

#### Scenario: Open question that options cannot answer
- **WHEN** the agent asks for information only the user has (a name, a
  secret, a free-form description)
- **THEN** no options are produced

#### Scenario: Model returns both
- **WHEN** the model output contains a valid continuation and valid options
- **THEN** only the options are stored

### Requirement: Option contract

Each option SHALL be at most 80 characters after trimming, options SHALL be
unique after case-insensitive comparison, and a set with fewer than 2 valid
options SHALL be discarded entirely. Options SHALL follow the language rule
already applied to the suggestion, and an option failing the script-mismatch
guard SHALL be dropped before the count check.

#### Scenario: One option survives validation
- **WHEN** the model returns three options and two are duplicates or too long
- **THEN** no options are stored

### Requirement: Options never act on their own

Options SHALL only be text. Producing, displaying, or selecting an option
SHALL NOT send a message, answer a pending question form, or grant a
permission.

#### Scenario: Option selected
- **WHEN** the user selects an option
- **THEN** the composer contains its text and no message has been sent

### Requirement: Gate keeps decision turns alive

The turn-end cost gate SHALL allow the suggestion field when either the turn
looks like unfinished agent work or the answer looks like it awaits a short
user decision. An unanswered gate question SHALL keep the field allowed, as
today.

#### Scenario: Decision turn passes the gate
- **WHEN** the gate rates "next step for the agent" low but "awaits a short
  user reply" high
- **THEN** the Small Model is asked for the suggestion field

### Requirement: Payload compatibility

`metadata.openchamber.assist` SHALL keep `recap`, `suggestion`,
`forMessageID`, and `generatedAt` with their current meaning and MAY carry
`options: string[]`. Freshness, the busy-time deletion, and the dismissal of a
payload SHALL apply to `options` exactly as to `suggestion`, and the setting
`sessionSuggestionEnabled` SHALL govern both.

#### Scenario: Suggestions disabled
- **WHEN** `sessionSuggestionEnabled` is off
- **THEN** neither `suggestion` nor `options` is requested or written

#### Scenario: Client without options support
- **WHEN** a client that does not know `options` reads a decision payload
- **THEN** it sees an empty suggestion and shows nothing, as before
