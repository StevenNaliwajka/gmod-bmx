# Vehicle models, built in code

Every vehicle in the addon is drawn as a real 3D model built from code: swept and
lathed tubes, extruded plates, lofted shells, with smooth normals, turned into
IMeshes once per size and drawn with lit VertexLitGeneric materials. Nothing is a
model file and nothing is borrowed from another game (docs/DESIGN.md section 8).

The BMX (`lua/bmx/cl_bikegeo.lua`) set the standard: a mid-school street BMX at
real dimensions, ~78k triangles: welded frame, laced 36-hole wheels with skinwall
tyres and a file tread, a modelled chain, three-piece cranks, pinned pedals, a
gyro, a bell. **Every other vehicle is held to that standard**: if you would not
mistake it for a real one of its kind at a glance in game, it is not done.

## Files

    lua/bmx/cl_bikegeo.lua     the primitives (G.prim), shared parts (G.parts),
                               the kind registry (G.Kinds) and the BMX itself
    lua/bmx/cl_geo_<name>.lua  one file per family of kinds, pure Lua, no GMod
                               calls: they run in a stock Lua 5.1 (the preview,
                               the tests) as well as in the game
    lua/bmx/cl_bikemesh.lua    turns a model into IMeshes, materials, lighting
    entities/bmx_base/cl_init.lua  DrawDetailed: places each group of a bike-
                               shaped model by one matrix
    tools/bike/export.lua, preview.py   render any kind offline (below)

A kind registers itself:

```lua
local G = BMX.BikeGeo
G.RegisterKind("road", function(opt, G) ... return M end)
```

and a vehicle asks for it in its registry entry: `look = "road"`.

## What a builder is handed

`opt`, in REAL Source units (inches):

| field | |
|---|---|
| `kind` | the kind's name |
| `wheelbase` | axle to axle; the axles are at x = -wheelbase/2 (rear) and +wheelbase/2 (front), z = 0, y = 0 |
| `radius` | the (front) wheel's outer radius |
| `rearRadius` | the rear wheel's, when it differs (a penny-farthing), else nil |
| `seat` | `{x, y, z}`: the rider's seat pod. **The top of the saddle goes at seat + (-0.5, 0, +2.0)** (the rider sits there) |
| `restLength` | the suspension's travel (Wheel.restLength) |
| `k` | wheelbase / 39: how big against a BMX, for sizing details |
| `extra` | anything vehicle-specific (a tandem's stoker seat) |

Model space is the vehicle's own: x forward, y LEFT, z up, origin on the axle
line midway between the axles. The drive side (chain) is the RIGHT, -y.

## What it returns

A model from `G.prim.newModel()`: `M:bucket(group, role, detail)` gives a list
to put triangles in; every primitive takes a bucket first. `detail = true` marks
small parts skipped at the far LOD (bolts, spokes' nipples, pins).

### Groups

Parts that move together. A bike-shaped kind uses these names, because
DrawDetailed places them:

| group | moves with |
|---|---|
| `frame` | the chassis (everything rigid: frame, saddle, rear brake, chain, mudguards, rack, lights, engine, bodywork) |
| `swingarm` | turns about `layout.swingPivot` (y axis) with the rear wheel's travel |
| `fork` | steers about the head tube (upper fork, crown, front mudguard if it steers) |
| `forkLower` | steers, and slides along the steer axis with the front wheel's travel (`layout.forkSlide`) |
| `bars` | steers (and spins, and turns down): stem, bars, grips, levers, the bell's dome |
| `bellLever` | the bell's lever, flicked about `layout.bellPivot` / `bellAxis` when it rings |
| `wheelF`, `wheelR` | built about THEIR OWN AXLE at the origin (x fwd, y = axle, z up); they spin |
| `cranks` | built in place about `layout.bb`; turn about the y axis through it |
| `pedal` | ONE pedal about its own centre, drawn at each crank tip |
| `childSeat` | drawn only while the child seat is switched on |

A kind with its own drawer (a unicycle, a scooter, a board, skates) chooses its own
group names and places them itself.

### Layout

`M.layout`, model space, plain `{x, y, z}` arrays (the game turns them into
Vectors; nested tables are fine):

| key | meaning |
|---|---|
| `headT`, `headB` | two points on the steer axis, top and bottom of the head tube |
| `steer` | the unit steer axis, pointing up |
| `rear`, `front` | the axles as built (normally `{-wb/2,0,0}`, `{wb/2,0,0}`) |
| `bb`, `crank`, `pedalY` | the crank centre, crank length, and how far out (y) the pedal's centre is from the bb at the crank tip |
| `pegs = { r = , l = }` | instead of pedals: where the rider's feet rest (a motorbike) |
| `gripR`, `gripL` = `{ A = , B = }` | each grip, inner end A, outer end B, in the bars' (unsteered) space. Right is -y. The hands hold them |
| `stemTop` | the turndown's pivot (default headT) |
| `swingPivot`, `shock = { frame =, swing =, r = }` | rear suspension |
| `forkSlide` | a telescopic fork's travel |
| `bb2`, `gripS = { r =, l = }` | a second crankset and the stoker's grips (a tandem) |
| `bellPivot`, `bellAxis` | the bell lever's hinge (G.parts.bell returns them) |
| `stand` | where the kickstand hangs from |
| `at = { group = { {x,y,z}, ... } }` | preview only: where to put a group built about its own origin |

The rider's hands and feet are put on these points by IK (cl_rider.lua), so they
must be where a rider's hands and feet would really be on that vehicle: the ball
of the foot goes 0.9 k above a pedal's centre or a peg's top, and the bar inside
the closed fist (tests/test_contacts.lua checks every registered vehicle).

A vehicle without pedals (`BMX.Motor.HasPedals` false: a throttle drive, or an
engine without `pedalStart`) has `pegs` and no `bb`, `cranks` or `pedal`, and no
drawing of it may show any. Its pegs are data in `G.Pegs` (cl_geo_moto.lua), so
the stand-in drawing puts them, and the feet, where the built model will.

## Materials (roles)

`paint` (the vehicle's palette colour), `black` (anodised/powder coat), `chrome`,
`alloy` (polished aluminium), `steel` (chain, rotors), `rubber` (tyres, grips),
`gum` (tan skinwall), `seat` (black saddle), `plastic` (black nylon), `white`
(white plastic), `wood` (maple veneer), `leather` (brown), `lens` (lamp glass),
`redlens` (tail light, reflectors), `amber` (indicators), plus the BMX's `decal`
and `tyretext`.

## Shared parts

- `G.parts.wheel(M, group, G.WheelDims(radius, { width, height, rimDepth, rimW }), opt)`:
  a complete wheel about its own axle. `opt`: `tread` = "file" | "knobby" |
  "slick" | "road"; `wall` = "gum" | "rubber"; `rim` = role; `spokes`, `cross`
  (0 = radial), `spokeR`; `mag = n` for a cast wheel; `disc = radius` for a rotor;
  `hubHalf`, `hubShell` (a drum or hub motor), `hubRole`; `rear = true` adds the
  BMX's 9t cog (`cog = false` to leave it off and build your own cassette).
- `G.parts.pedal(M, group)`: the BMX's pinned platform pedal.
- `G.parts.bell(M, group, leverGroup, at, barDir, up, toward)`: the bell; returns
  the lever's pivot and axis for the layout.
- `G.parts.toothLoop(n, pitchRadius)`, `G.parts.pitchRadius(n)`: sprockets.
- `G.prim`: sweep, lathe, plate, ringPlate, box, roundRect, circle, bez3,
  spline, tri, quad, grid, cap, bead, earclip, newModel; `G.vec`: V, add, sub,
  mul, dot, cross, len, norm, lerp, rot, madd, perp. Read their comments in
  cl_bikegeo.lua: winding is handled for you (normals decide).

## Budget

- Under ~90k triangles a kind (the BMX is 79k), and it must build offline in
  under 2 s (`lua5.1 tools/bike/export.lua kind=<name>` prints both).
- Small parts (bolts, pins, cable ends, nipples) in `detail` buckets.

## Looking at it

    lua5.1 tools/bike/export.lua kind=road > /tmp/road.txt
    python3 tools/bike/preview.py /tmp/road.txt /tmp/road.png three 1200 800
    # views: side front rear three top low close-drive close-front close-bars close-seat
    # BMX_PAINT=0.1,0.3,0.8 for another frame colour

`tools/bike/sizes.lua` holds each kind's registry size for this. Look at every
view before calling a model done; compare with the BMX
(`lua5.1 tools/bike/export.lua > /tmp/bmx.txt`).

In game, `tools/ride/shoot.sh <id>` photographs it ridden, and
`tools/icons/shoot.sh bmx_<id>` re-shoots its spawn-menu picture (every menu
entry's picture must show the real item: shoot it again when the look changes).
