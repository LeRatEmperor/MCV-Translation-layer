return [===[<!doctype html>
<html><head><meta charset="utf-8"><style>
body { margin: 0; padding: 24px 32px; background: #f7f7f5; color: #222;
    font: 16px/1.6 Arial, sans-serif; }
main { max-width: 820px; margin: auto; }
h1 { font-size: 27px; line-height: 1.25; }
h2 { font-size: 21px; margin-top: 32px; }
a { color: #145b91; }
pre { overflow-x: auto; padding: 14px; background: #e7e7e4; line-height: 1.4; }
code { font: 14px/1.4 monospace; }
li { margin-bottom: 8px; }
</style></head><body><main><h1>Porting a weapon with its original animations</h1>
<p>The part that usually goes wrong is the rig. A mesh and a folder of animation files are not enough: they must use the same skeleton, bind pose and scale. Get one idle animation working before adding reloads, upgrades or effects.</p>
<p>This guide starts with a weapon you can export from its source game. Extraction depends on the game and engine; DHRB does not extract assets or convert cooked game files. The aim here is to get an animated model into Garry's Mod and then make a DHRB weapon use it.</p>
<h2>1. Collect a complete weapon</h2>
<p>Export the weapon mesh, arm mesh if it has one, skeleton, textures and animation clips. Keep any separate magazine, cartridges, slide, bolt and other moving parts. Also record the clips' frame rates and the names of their skeletons. A reload often has more than one version: empty magazine, tactical reload, individual shell insertions and the final pump or bolt action.</p>
<p>Check how the source game assembles the weapon. Arms and gun may be separate skeletal meshes driven by one animation, or two skeletons with a socket between them. If the magazine is a separate object, export that too. A flattened scene export can look right at rest and lose all of those moving parts.</p>
<p>Use an exporter that supports that game's version. For Unreal games, mesh/animation export tools need the right engine support and sometimes a matching mapping file. For Unity games, scene/project exports can help recover the rig, but an Animator controller is not itself an animation clip. Neither route produces a finished Source model.</p>
<h2>2. Check the rig in Blender</h2>
<p>Import the mesh and a single animation onto the same armature. Scrub the animation. The magazine should follow the hand when it comes out, and the gun should stay in the grip. Fix detached parts, reversed axes and incorrect rest poses here.</p>
<p>Keep the original rig as a reference. Work on a copy. Apply the same scale and orientation change to the mesh, armature and every clip; scaling only the mesh causes sliding hands and flying magazines. Match a stock GMod viewmodel as a size reference. If the exporter really uses centimetres, start with 0.3937 Source units per centimetre, then check the result against that reference.</p>
<p>Bake constraints and control-rig motion onto deform bones before exporting. Export the bones which actually skin the model, plus any bones needed for attachments. Do not rely on Blender-only IK constraints surviving the export.</p>
<p>Keep the original timing. A 60 fps clip exported as the same number of frames at 30 fps takes twice as long. Either preserve the original frame rate or resample the movement over the same duration.</p>
<h2>3. Decide how the hands will work</h2>
<p>For fixed arms, keep the imported arm mesh and its animation rig together. Start with <code>SWEP.UseHands = false</code> so another pair of arms is not drawn over them.</p>
<p>For player-model hands, retarget the arm and finger animation to a compatible c_model skeleton, remove the fixed arm mesh from the weapon, and use <code>SWEP.UseHands = true</code>. Renaming bones alone does not correct their rest rotations or proportions. Test the thumb, trigger finger and support grip through the entire reload.</p>
<p>Facepunch provides c_model and arm source files, including the bone definitions needed to stop the compiler removing unused arm bones: <a href="https://wiki.facepunch.com/gmod/Using_Viewmodel_Hands">Using Viewmodel Hands</a>.</p>
<h2>4. Export the model and each clip</h2>
<p><a href="https://github.com/Artfunkel/BlenderSourceTools">Blender Source Tools</a> exports Source formats from Blender. Export one reference mesh and one animation per action. Use one skeleton definition throughout. Keep the bind pose and animated idle as separate exports.</p>
<p>A small working folder might contain:</p>
<pre><code class="language-text">c_example.qc
reference.smd
anims/idle.smd
anims/draw.smd
anims/fire.smd
anims/reload.smd
</code></pre>
<p>At this stage the weapon should already animate correctly in Blender. A compiler will not fix a magazine that was attached to the wrong bone or a clip baked against another skeleton.</p>
<h2>5. Write a QC and compile</h2>
<p>The QC gives the model its path, materials, attachments and named sequences. This is a starting point for a fixed-arm viewmodel. Replace the mesh/material paths and attachment bone names with the ones in your export.</p>
<pre><code class="language-text">$modelname &quot;weapons/my_pack/c_example.mdl&quot;
$body &quot;weapon&quot; &quot;reference.smd&quot;
$cdmaterials &quot;models/my_pack/example/&quot;
$surfaceprop &quot;metal&quot;

$attachment &quot;muzzle&quot; &quot;muzzle_bone&quot; 0 0 0 rotate 0 0 0
$attachment &quot;shell&quot; &quot;eject_bone&quot; 0 0 0 rotate 0 0 0

$sequence &quot;idle&quot; &quot;anims/idle.smd&quot; fps 30 loop activity ACT_VM_IDLE 1
$sequence &quot;draw&quot; &quot;anims/draw.smd&quot; fps 30 activity ACT_VM_DRAW 1
$sequence &quot;fire&quot; &quot;anims/fire.smd&quot; fps 30 activity ACT_VM_PRIMARYATTACK 1
$sequence &quot;reload&quot; &quot;anims/reload.smd&quot; fps 30 activity ACT_VM_RELOAD 1
</code></pre>
<p>Use your clips' actual frame rate, not necessarily 30. Attach <code>muzzle</code> to the barrel tip and <code>shell</code> to the ejection port. Their orientation matters as well as their position. Inspect them in the model viewer rather than guessing from the gun's origin.</p>
<p>Compile with a Source compiler compatible with GMod. Crowbar is a front end for decompiling/compiling; compilation still needs the appropriate compiler and game path. Read the compiler log and inspect the model before copying it into an addon.</p>
<p>The output is a set of files: <code>.mdl</code>, <code>.vvd</code>, <code>.vtx</code> variants and sometimes <code>.phy</code>. Copy the files the compiler actually produced together. A lone <code>.mdl</code> is not the whole model. Compile a separate world model for the gun other players see; it needs its own grip placement and a collision mesh if it will be a physical pickup.</p>
<h2>6. Convert the materials</h2>
<p>Source uses a VMT to choose a shader and its settings, with VTF textures underneath. Start with a diffuse texture and a plain <code>VertexLitGeneric</code> material:</p>
<pre><code class="language-text">&quot;VertexLitGeneric&quot;
{
    &quot;$basetexture&quot; &quot;models/my_pack/example/body&quot;
    &quot;$bumpmap&quot; &quot;models/my_pack/example/body_normal&quot;
}
</code></pre>
<p>Remove the bump-map line until you have a valid normal map. Texture paths are relative to <code>materials</code>, without the extension. The material name referenced by the mesh must match the VMT filename under the QC's material search path.</p>
<p>Metallic/roughness maps from another engine are not direct replacements for Source phong or cubemap masks. Get the colour and normals right first, then tune reflections under both bright outdoor light and indoor lighting. Check texture channels and normal-map orientation before compensating with extreme shader settings.</p>
<h2>7. Give DHRB the sequence names</h2>
<p>Make a separate addon. Keep its class names and model/material paths unique. This file goes in <code>lua/weapons/my_example.lua</code>:</p>
<pre><code class="language-lua">AddCSLuaFile()
include(&quot;dhr/core.lua&quot;)

SWEP.Base = &quot;dhr_base&quot;
SWEP.PrintName = &quot;Example Pistol&quot;
SWEP.Category = &quot;My Weapons&quot;
SWEP.Spawnable = true
SWEP.UseHands = false
SWEP.HoldType = &quot;pistol&quot;
SWEP.ViewModel = &quot;models/weapons/my_pack/c_example.mdl&quot;
SWEP.WorldModel = &quot;models/weapons/my_pack/w_example.mdl&quot;
SWEP.Primary.ClipSize = 12
SWEP.Primary.DefaultClip = 36
SWEP.Primary.Ammo = &quot;Pistol&quot;
SWEP.Primary.Automatic = false

DHR.Define(SWEP, {
    damage = 8,
    rate = 4,
    spread = 0.025,
    kick = 1,
    hold_fire = true,
    fire_snd = &quot;Weapon_Pistol.Single&quot;,
    dry_snd = &quot;Weapon_Pistol.Empty&quot;,
    seq = {
        idle = &quot;idle&quot;,
        draw = &quot;draw&quot;,
        fire = {&quot;fire&quot;},
        reload = &quot;reload&quot;,
    },
})
</code></pre>
<p>The model names here are examples, not included assets. DHRB's damage multiplier applies to <code>damage</code>; its default is 2.5. <code>rate</code> is shots per second. <code>hold_fire</code> uses the player's hold-to-fire option. The normal GMod hold type handles the world model unless you supply a custom pose.</p>
<p>You can use sequence names even if the model has no <code>ACT_VM_*</code> activities assigned. <code>DHR.Define</code> maps existing compiled animations to DHRB actions; it does not create missing animations or adapt the logic of a SWEP written for another base.</p>
<p>DHRB checks required sequences when the weapon is equipped. Use the exact compiled names. Lua cannot play an Unreal montage or a Blender action that has never been exported and compiled into the model.</p>
<h2>8. Put sounds and reload events on the right frame</h2>
<p>A useful reload needs more than a sequence name. Find when the old magazine leaves the hand, the new one seats and the bolt moves. Add each first-person sound at that frame in the QC. For a custom cue, register its sound name in shared Lua before using it.</p>
<pre><code class="language-text">$sequence &quot;reload&quot; &quot;anims/reload.smd&quot; fps 30 activity ACT_VM_RELOAD 1
{
    { event 5004 12 &quot;Weapon_Pistol.Reload&quot; }
}
</code></pre>
<p>For observers, put the same cue in DHRB's <code>world_events</code>, keyed by the compiled sequence name:</p>
<pre><code class="language-lua">world_events = {
    reload = {
        {time = 0.4, sound = &quot;Weapon_Pistol.Reload&quot;},
    },
},
</code></pre>
<p>That example places a cue at frame 12 of a 30 fps sequence: 0.4 seconds. In your weapon, use the measured contact time. Listen from another player's position as well as in first person; a reload which sounds right to its owner may still be silent to everyone else.</p>
<p>For a pump shotgun, use separate <code>reload_start</code>, <code>reload_loop</code> and <code>reload_end</code> roles. If the firing clip already contains its pump, keep that complete action together. If the pump is a separate clip, supply <code>pump</code> and <code>pump_delay</code>. Do not shorten the firing delay until the mechanism has finished moving.</p>
<h2>9. Add features after the basic gun works</h2>
<p>Tune ADS against the sights on the compiled model. DHRB accepts a positional <code>aim</code> offset or dedicated <code>ads_idle</code>, <code>ads_fire</code>, <code>ads_in</code> and <code>ads_out</code> sequences. Test firing while entering and leaving ADS.</p>
<p>An upgrade which changes a magazine or barrel needs the corresponding mesh or bodygroup and animation support. Changing magazine capacity in Lua does not make the longer magazine fit a reload. Watch the handoff between the animated magazine and any dropped world object.</p>
<p>Executions need both sides of the action: attacker motion, victim motion, contact timing and matching placement. Register a complete execution profile with DHRB. A first-person stabbing clip alone cannot make an arbitrary NPC's head line up with the hand. Start with a compatible humanoid and then check different heights and models.</p>
<p>Dual wielding needs a usable one-handed pose, independent clips and a reload where the waiting gun gets out of the support hand's way. Do not just mirror a two-handed viewmodel: that gives you extra hands.</p>
<h2>10. Check the packaged addon</h2>
<p>Test draw, fire, empty fire, full and partial reloads, ADS transitions and holstering. Check the muzzle and shell positions while aiming and moving. Compare the animation's duration in the source game with the compiled sequence, not just its frame count.</p>
<p>Use a dedicated server with a second client to check sounds, reloads, world models and ammunition. Try different player models if you support c_hands. Test your GMA with the development folders removed from the mount path; missing materials are easy to hide with a working source installation.</p>
<p>Ship the weapon Lua and required models, materials and sounds. Leave Blender files, source exports, logs and test tools out of the runtime addon. Add DHRB as a required Workshop item instead of copying its runtime into your pack.</p>
<h2>Common faults</h2>
<ul>
<li><strong>The mesh explodes during reload:</strong> the animation and reference mesh use different bind poses, bone indices or scales.</li>
<li><strong>The clip is too fast:</strong> exported sample rate and QC <code>fps</code> disagree, or an extra Lua playback multiplier is active.</li>
<li><strong>The gun is fine but the fingers twist:</strong> check rest rotations and retargeting, not just bone names.</li>
<li><strong>Extra arms appear:</strong> fixed arm geometry and c_hands are both enabled.</li>
<li><strong>Purple and black materials:</strong> check the VMT path, mesh material name and whether the VTF is inside the addon.</li>
<li><strong>Muzzle flash appears at the grip:</strong> the attachment is missing, placed at the wrong bone or read from the wrong rendered model.</li>
<li><strong>It works only on your PC:</strong> test the archive with local source unmounted and verify its required addons.</li>
</ul>
<h2>References</h2>
<ul>
<li><a href="https://steamcommunity.com/sharedfiles/filedetails/?id=3813410489">DHRB Workshop page</a></li>
<li><a href="https://github.com/Artfunkel/BlenderSourceTools">Blender Source Tools</a></li>
<li><a href="https://wiki.facepunch.com/gmod/Using_Viewmodel_Hands">GMod c_hands setup and source files</a></li>
<li><a href="https://wiki.facepunch.com/gmod/Structures/SWEP">GMod scripted weapon structure</a></li>
<li><a href="https://developer.valvesoftware.com/wiki/SMD">Valve SMD format</a></li>
<li><a href="https://developer.valvesoftware.com/wiki/$sequence">Valve sequence QC reference</a></li>
<li><a href="https://developer.valvesoftware.com/wiki/Compiling_a_model">Valve model compilation reference</a></li>
</ul>
</main>
<script>
document.addEventListener('click', function(event) {
    var link = event.target;
    while (link && link.tagName !== 'A') link = link.parentElement;
    if (!link) return;
    event.preventDefault();
    dhrguide.openLink(link.href);
});
</script></body></html>]===]
