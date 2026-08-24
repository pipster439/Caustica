package dev.comfyfluffy.caustica.client.gui;

import dev.comfyfluffy.caustica.CausticaConfig;
import dev.comfyfluffy.caustica.client.RtVideoOptions;
import net.minecraft.client.Options;
import net.minecraft.client.gui.screens.Screen;
import net.minecraft.client.gui.screens.options.OptionsSubScreen;
import net.minecraft.network.chat.Component;

/**
 * Dedicated subscreen hosting the runtime-tunable ray tracing settings.
 * Persists modified settings to the TOML configuration file upon closing.
 */
public class CausticaOptionsScreen extends OptionsSubScreen {
    private static final Component TITLE = Component.translatable("caustica.options.rt.header");

    public CausticaOptionsScreen(Screen lastScreen, Options options) {
        super(lastScreen, options, TITLE);
    }

    @Override
    protected void addOptions() {
        if (this.list != null) {
            this.list.addSmall(RtVideoOptions.runtimeOptions());
        }
    }

    @Override
    public void removed() {
        super.removed();
        CausticaConfig.save();
    }
}
