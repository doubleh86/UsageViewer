using System.Text.Json;

namespace UsageViewer.Services;

internal sealed record PopupPreferences(bool ShowBoth = true, string ActiveProvider = "codex",
                                        bool ShowTopBar = true, bool AlwaysOnTop = true,
                                        string? TopBarScreen = null, double TopBarPosition = 0.5,
                                        bool AlertSoundEnabled = true);

internal sealed class PopupPreferencesStore
{
    private readonly string _path;

    public PopupPreferencesStore(string? path = null)
    {
        _path = path ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                                     "UsageViewer", "view.json");
    }

    public PopupPreferences Load()
    {
        try
        {
            if (File.Exists(_path) == false || new FileInfo(_path).Length > 4096)
            {
                return new PopupPreferences();
            }

            PopupPreferences? preferences = JsonSerializer.Deserialize<PopupPreferences>(File.ReadAllText(_path));

            if (preferences == null)
            {
                return new PopupPreferences();
            }

            return preferences with
            {
                ActiveProvider = new[] { "codex", "claude", "gemini", "cursor", "copilot" }
                    .Contains(preferences.ActiveProvider) == true ? preferences.ActiveProvider : "codex",
                TopBarPosition = double.IsFinite(preferences.TopBarPosition) == true ?
                                 Math.Clamp(preferences.TopBarPosition, 0, 1) : 0.5
            };
        }
        catch (Exception exception) when (exception is IOException || exception is UnauthorizedAccessException ||
                                          exception is JsonException)
        {
            return new PopupPreferences();
        }
    }

    public bool Save(PopupPreferences preferences)
    {
        string temporaryPath = _path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(_path))!);
            File.WriteAllText(temporaryPath, JsonSerializer.Serialize(preferences));
            File.Move(temporaryPath, _path, overwrite: true);

            return true;
        }
        catch (Exception exception) when (exception is IOException || exception is UnauthorizedAccessException)
        {
            return false;
        }
        finally
        {
            try
            {
                File.Delete(temporaryPath);
            }
            catch (Exception exception) when (exception is IOException || exception is UnauthorizedAccessException)
            {
            }
        }
    }
}
