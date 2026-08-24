package dev.comfyfluffy.caustica.mixin;

import dev.comfyfluffy.caustica.client.gui.SodiumButtonHelper;
import net.minecraft.client.gui.screens.Screen;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Pseudo;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

/**
 * Injects a Ray Tracing settings button into SodiumOptionsGUI screen instances.
 */
@Pseudo
@Mixin(targets = "net.caffeinemc.mods.sodium.client.gui.SodiumOptionsGUI")
public abstract class SodiumOptionsGuiMixin {
    @Inject(method = "init", at = @At("RETURN"))
    private void caustica$addSodiumRtButton(CallbackInfo ci) {
        SodiumButtonHelper.addRayTracingButton((Screen) (Object) this);
    }
}
