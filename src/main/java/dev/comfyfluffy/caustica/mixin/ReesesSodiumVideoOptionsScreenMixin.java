package dev.comfyfluffy.caustica.mixin;

import dev.comfyfluffy.caustica.client.gui.SodiumButtonHelper;
import net.minecraft.client.gui.screens.Screen;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Pseudo;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

/**
 * Injects a Ray Tracing settings button into Reese's Sodium Video Options screen instances.
 */
@Pseudo
@Mixin(targets = "me.flashyreese.mods.reeses_sodium_options.client.gui.SodiumVideoOptionsScreen")
public abstract class ReesesSodiumVideoOptionsScreenMixin {
    @Inject(method = "init", at = @At("RETURN"))
    private void caustica$addReesesSodiumRtButton(CallbackInfo ci) {
        SodiumButtonHelper.addRayTracingButton((Screen) (Object) this);
    }
}
