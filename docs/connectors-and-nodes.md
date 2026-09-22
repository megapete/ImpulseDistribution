# `Connector` / `Segment.Connection`, node topology, and terminations

Read this before touching `Connector.swift`, `SetNodes`, `NodeAt`, `IsTappingGap`, `UpdateConnectors`,
`ResolveNodeConnectivity`, or any of `TransformerView`'s mouse handlers that add/remove connections.

A `Connector` is an electrical "jumper". It has a `fromLocation`/`toLocation` from the `Connector.Location` enum: eight physical
points on a segment (`{inside,center,outside}_{upper,lower}` plus `outside_center`/`inside_center`) and the special *terminations*
`floating`, `ground`, `impulse`. A `Segment.Connection` pairs a `Connector` with an optional `segmentID`: non-nil ⇒ a jumper to
that segment's location; nil ⇒ a termination on `self`. Coil ends and tapping gaps carry a `floating` lead by default;
`AddConnector` **replaces** a floating lead with ground/impulse but **appends** a segment-to-segment jumper (leaving the floating
lead in place).

## A tapping gap breaks the node chain even when it is bridged

`outside_center`/`inside_center` connectors are created in exactly one place — `AppController:1030-1044`, at tapping/DV gaps — and
`Connector.AlternatingLocation` only ever pairs a center location with another center location; a real series connection between
adjacent discs always maps an **upper** location to a **lower** one. So a center connector means "tapping gap", always. `SetNodes`
therefore gives each side of a gap its own node, testing `IsTappingGap` *as well as* the presence of a connection — matching
`NonAdjacentConnections`' rule that gap jumpers "will be adjacent, but for the purposes of the simulation they will not be". The
jumper is then tied up explicitly through `finalConnectedNodes` → `mergedNodes` → the `V_eliminated − V_kept = 0` row surgery.
Testing only for a connection (as `SetNodes` did until 2026-08-04) made a *bridged* gap look continuous, so `NodeAt` — which
resolves a center connector only to a dangling node — could not find the node its own connector described, and
`SimulationModel.init` failed. **Both routines must keep using the same predicate** — and `SetNodes` now ends by calling
`VerifyNodeTopology()`, which asks `NodeAt` to resolve every connector in the model and throws `.UnresolvableConnector` if one
fails. Note what that guard deliberately is *not*: a node **count** check (`nodes == segments + breaks + coils`) is a tautology,
because `breaks` comes from the same predicate — it held perfectly while the bug was live. Only a check that crosses the
`SetNodes`/`NodeAt` boundary can see a wrong break decision. Relatedly, neither operation that *regroups* a selection
(`doInterleaveSelection`, `doAddWoundInShields`' pairing path) may run across a gap: flattening would swallow the break into the
middle of a Segment and strand its two center leads. Both call `AppController.SelectionSpansTappingGap` and refuse.

## `IsTappingGap` recognises a gap by the LOCATION, not by the termination

Until 2026-08-07 it did the opposite, which cost the same failure a second time. Its test was for a *floating* lead facing across
the boundary from each side, and `AddConnector` **replaces** a floating lead with a ground or an impulse. So a designer doing the
ordinary thing with a double-stacked winding — tie the two centre leads together, ground them, which is what a centre-grounded tap
winding *is* — leaves neither side floating and erases the only evidence the gap existed. `SetNodes` then read the bridging jumper
as a series connection, gave the two sides one shared node, and `NodeAt` could not find the dangling node a centre connector
insists on: *"segment 168 has a connector at outside_center with no node there (target: 169)"*. Since a centre location is only ever
created at a gap, the location is permanent evidence and the termination is not, so the predicate now accepts `fromIsCenter`
whatever it is tied to. **Both sides must still agree**, and that is not belt-and-braces: the Segment *above* a gap carries a centre
lead facing down, so testing either side alone would report the boundary above *it* as a gap too. `SelfTest`'s **`S0738`** scenario
is this case end to end.

## One jumper is stored as up to four connections, and a fold is where that bites

A node is shared by the two Segments that meet at it, and `TransformerView.CompleteAddConnection` registers a new jumper on **every** (Segment,
location) pair at each of its two ends — the whole cross-product, each copy carrying the others in its `equivalentConnections`. So
a jumper dropped between discs 10 and 11 lives on *both* discs (and on both discs at the far end). While those discs are separate
Segments the copies describe the same node and are drawn a disc-gap apart, i.e. on top of each other. **Fold the two discs into one
Segment and they no longer do**: `NodeAt` resolves a connection by upper/lower alone, so disc 10's copy (an *upper* location) comes
back on the new Segment's **top** node and disc 11's (a *lower* location) on its **bottom** node. That drew two connector lines
where the user made one — and `SimulationModel.init` unions the node groups a jumper ties together, so it also **shorted the new
Segment out**, silently, with a plausible answer at the end of it. Three things now stand between that and a wrong answer, and they
are meant to be read together:

- `PhaseModel.UpdateConnectors` inherits **only** the connections at the two surviving terminals (lower-locations from the first old
  Segment, upper-locations from the last) and sweeps away the **mirror** of everything it discards — matching on the old serial
  number *and* the connector, which is what `Segment.RemoveConnectionsMatching` is for. Dropping one half only re-attaches the jumper
  from the other side, so both halves have to go together, and the sweep has to run **before** the serial remap.
- `AppController.SelectionStrandedConnection` refuses the operation first, so the loss is the user's decision rather than a silent
  one. It is called by *Combine*, *Interleave* and the wound-in-shield **rebuild** path, and is conservative over the whole selection
  for the same reason `SelectionSpansTappingGap` is.
- `SegmentPath.SetUpConnectors` draws **one line per equivalence class**, so the redundant copies never reach the screen (and
  `assignLane` stops spreading them into parallel lanes as though they were separate connections).

`SelfTest`'s **`STRANDED`** run (`-PCH_SelfTest STRANDED`) puts a jumper on a node interleaving is about to swallow and checks all
three: the guard sees it, neither end still names the other afterwards, and no node group ties the merged Segment's two terminals.

## A termination lives only on the lead the user clicked

What is at that potential *through a jumper* is derived, never stored (2026-08-08). `PhaseModel.ResolveNodeConnectivity()` is the
single place that answers "which nodes are at ground / at the impulse / genuinely floating / merely shorted to each other": it
takes the *directly* terminated nodes from `NodesOfType` (which does **not** follow jumpers — its doc says so), unions the jumper
edges from `NonAdjacentConnections` with a real **union-find**, and closes the terminations over the components. Everything that
needs the answer uses it — `SimulationModel.init`, the SPICE export, the initial-distribution picker, `SelfTest`.

It used to be the other way round. `TransformerView.mouseDownWithAddGround`/`AddImpulse` walked `ConnectionDestinations` and
wrote a `.ground` connector onto **every** jumpered lead as well, and those copies had no link back to the jumper that justified
them. That is a cache with no invalidation, and pulling the jumper left them behind. The reported failure: re-wiring S0738's
double-stacked tap winding from series to parallel — ground the HV neutral in its own right, then remove the old jumper that used
to carry it through the tap winding — left the tap winding's two outer ends **still grounded, pinned at exactly 0 for the whole
run**, with nothing on screen at the HV neutral to explain it. Doing the same two edits in the *other* order gave a different
model from the same picture, which is the tell. Note what the symptom is *not*: an exact zero is what the Dirichlet row surgery
writes, so a lead reading zero means the model has it in `groundedNodes` — it is never a floating node needing a bleed resistance
(see `SimulationModel.floatingResistanceToGround`, which is deliberately inert and says why).

The same change deleted `SimulationModel.init`'s own reduction of the jumper graph, which was **not** a union-find: it absorbed
into each key only those other keys whose sets named that key, which is enough for a star (what `CompleteAddConnection`'s cross-product makes)
and not for a path. A-B, B-C came out as the two *overlapping* groups `A:{B,C}` and `C:{B}`; `FrequencyDomainSolver.Assemble`
then folds merges in dictionary order, and an order exists in which a node's charge equation is added to a row already replaced
by a constraint — the group's charge balance is silently wrong. Proper components make each node an `eliminated` exactly once and
never make a `kept` node an `eliminated`, which is the invariant assembly relies on and which `Snapshot()` still asserts.

## Regulating windings: permanent connections made from a declaration (2026-09-22)

*Connections → Regulating Winding…* declares the selected coil a regulating (tapping) winding and puts on the connections that are
a permanent part of it (`RegulatingWinding.swift`, dialog in `RegulatingWindingDialog.swift`). The user gives only the number of
**loops**; the **arrangement** — double-stacked, multi-start or single stack — is read from the design file every time and never
stored. Only a double-stacked disc winding gets jumpers: with N discs and L loops per stack, d = N/(2L) discs per loop, the two outer
ends are tied together, the crossover above disc k·d is tied to the one above disc N − k·d for k = 1…L−1, and the two centre leads
are tied together — L + 1 jumpers. A stack that does not divide evenly into loops is refused, not rounded. A multi-start winding is
one lumped section with nothing to connect (`docs/decisions.md` §2c); a single stack brings every tap lead out.

The declaration is saved per design file in `RegulatingWindingStore` (a port of PchMagneticFlux's `TapDefinitionsStore`: one JSON
file in the sandbox's Application Support, keyed by the design's path) and **re-applied when that design is next opened** — in
`updateModel`, right after `initializeModel` and before `initializeViews`, while every lead is floating and every coil is one disc
per Segment. Only `doOpen` passes the design URL, so a SelfTest run never reads or writes the user's declarations.

Things that are deliberate:

- **Every point is a `Wiring.LeadPoint`, found and never computed** — the machinery `SelfTest` used for its scenarios, moved into
  `Wiring.swift` so the app could share it (`SelfTest.LeadPoint`/`Jumper`/`CoilEnd` are typealiases of it now). The centre gap is
  found by `Wiring.InternalGaps`, the same centre-location predicate as `IsTappingGap`, and `CheckModel` refuses a coil that is not
  one disc per Segment or that does not have exactly one gap in the middle (a double-stacked winding *with* off-load taps is cut at
  the quarter points instead).
- **Only jumpers are written, never terminations** (standing rule 6). Coil-end leads are found with `acceptTerminated: true`, so a
  winding whose end was grounded first still gets its ties, beside the ground rather than in place of it.
- **Applying is all-or-nothing on lookup and idempotent on the jumpers**: every lead is found before any jumper goes on, and a jumper
  already there (`Wiring.IsApplied`: a *direct* connection between the two leads) is skipped, so applying twice is applying once.
- **Changing the loop count takes the old ties off first** (`Remove` → `Wiring.RemoveJumper`), or both sets would be on the winding at
  once. `RemoveJumper` matches the connection on both Segments **and** both locations: at one disc per loop, adjacent tap jumpers
  share a Segment, and matching on the far Segment alone (which is what `SelfTest.ApplyRemoval` does) could take the wrong one.

`SelfTest`'s **`T0223-tap-declared`** is the check: `T0223-tap-parallel` with coil 3's nine hand-listed jumpers replaced by a
declaration of 8 loops. It applies the declaration, applies it again (nothing made), changes it to 1 loop and back (9 removed,
2 made and removed, 9 restored) and must then print the same `Connectivity:` line as `T0223-tap-parallel` — it does.
`RegulatingWinding.VerifySelf()` (under `-PCH_Verify YES`) pins the generator itself.

