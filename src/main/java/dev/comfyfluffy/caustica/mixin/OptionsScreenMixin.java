package dev.comfyfluffy.caustica.mixin;

import dev.comfyfluffy.caustica.CausticaConfig;
import dev.comfyfluffy.caustica.client.gui.CausticaOptionsScreen;
import net.minecraft.client.Minecraft;
import net.minecraft.client.gui.components.Button;
import net.minecraft.client.gui.screens.Screen;
import net.minecraft.client.gui.screens.options.OptionsScreen;
import net.minecraft.network.chat.Component;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

/**
 * Injects a Ray Tracing button into the main OptionsScreen for direct access to Caustica settings.
 */
@Mixin(OptionsScreen.class)
public abstract class OptionsScreenMixin {
    private static final Component RT_BUTTON_TEXT = Component.translatable("caustica.options.rt.button");

    @Inject(method = "init", at = @At("RETURN"))
    private void caustica$addRtButtonToOptions(CallbackInfo ci) {
        if (!CausticaConfig.Rt.ENABLED.value()) {
            return;
        }
        Screen screen = (Screen) (Object) this;
        int buttonWidth = 100;
        int buttonHeight = 20;
        int x = screen.width - buttonWidth - 8;
        int y = 8;
        Button button = Button.builder(
                RT_BUTTON_TEXT,
                btn -> Minecraft.getInstance().setScreenAndShow(new CausticaOptionsScreen(screen, Minecraft.getInstance().options)))
            .bounds(x, y, buttonWidth, buttonHeight)
            .build();
        ((ScreenAccessor) screen).caustica$addRenderableWidget(button);
    }
}
