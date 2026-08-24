package dev.comfyfluffy.caustica.client.gui;

import dev.comfyfluffy.caustica.CausticaConfig;
import dev.comfyfluffy.caustica.mixin.ScreenAccessor;
import net.minecraft.client.Minecraft;
import net.minecraft.client.gui.components.Button;
import net.minecraft.client.gui.screens.Screen;
import net.minecraft.network.chat.Component;

/**
 * Utility for embedding the Ray Tracing settings navigation button into Sodium video options screens.
 */
public final class SodiumButtonHelper {
    private static final Component RT_BUTTON_TEXT = Component.translatable("caustica.options.rt.button");

    private SodiumButtonHelper() {
    }

    public static void addRayTracingButton(Screen screen) {
        if (!CausticaConfig.Rt.ENABLED.value()) {
            return;
        }
        int buttonWidth = 100;
        int buttonHeight = 20;
        int x = 8;
        int y = screen.height - 27;
        Button button = Button.builder(
                RT_BUTTON_TEXT,
                btn -> Minecraft.getInstance().setScreenAndShow(new CausticaOptionsScreen(screen, Minecraft.getInstance().options)))
            .bounds(x, y, buttonWidth, buttonHeight)
            .build();
        ((ScreenAccessor) screen).caustica$addRenderableWidget(button);
    }
}
