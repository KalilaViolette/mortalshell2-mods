-- MortalShell2TTS settings option catalogs.
-- TTS-specific static data only: no Unreal objects, hooks, helper IPC, or rendering.

local Options = {}

Options.engines = {
    {
        value = "system_speech",
        label = "Windows Speech",
        mode = "Local / Offline",
        supports_audio_output = true,
    },
    {
        value = "azure",
        label = "Microsoft Azure",
        mode = "Cloud / Streaming",
        supports_audio_output = true,
    },
}

Options.azure_regions = {
    "eastus", "eastus2", "westus", "westus2", "westus3", "centralus",
    "northcentralus", "southcentralus", "canadacentral", "brazilsouth",
    "northeurope", "westeurope", "uksouth", "francecentral", "germanywestcentral",
    "swedencentral", "switzerlandnorth", "norwayeast", "eastasia", "southeastasia",
    "japaneast", "japanwest", "koreacentral", "centralindia", "australiaeast",
    "uaenorth", "southafricanorth",
}

return Options
