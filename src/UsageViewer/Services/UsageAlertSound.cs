using System.Media;
using System.Text;

namespace UsageViewer.Services;

internal sealed class UsageAlertSound : IDisposable
{
    private readonly MemoryStream _stream = new MemoryStream(CreateWave(), writable: false);
    private SoundPlayer? _player;

    public void Play()
    {
        try
        {
            _player ??= new SoundPlayer(_stream);
            _player.Play();
        }
        catch (Exception exception) when (exception is InvalidOperationException || exception is IOException ||
                                          exception is TimeoutException || exception is System.ComponentModel.Win32Exception)
        {
            // Visual alerts remain available on devices without audio playback.
        }
    }

    public void Stop()
    {
        _player?.Stop();
    }

    internal static byte[] CreateWave()
    {
        const int sampleRate = 22050;
        const double duration = 1.2;
        int samples = (int)(sampleRate * duration);
        using MemoryStream stream = new MemoryStream();
        using BinaryWriter writer = new BinaryWriter(stream, Encoding.ASCII, leaveOpen: true);
        writer.Write(Encoding.ASCII.GetBytes("RIFF"));
        writer.Write(36 + samples * 2);
        writer.Write(Encoding.ASCII.GetBytes("WAVEfmt "));
        writer.Write(16);
        writer.Write((short)1);
        writer.Write((short)1);
        writer.Write(sampleRate);
        writer.Write(sampleRate * 2);
        writer.Write((short)2);
        writer.Write((short)16);
        writer.Write(Encoding.ASCII.GetBytes("data"));
        writer.Write(samples * 2);
        double phase = 0;
        for (int sample = 0; sample < samples; sample++)
        {
            double time = sample / (double)sampleRate;
            double cycle = time % 0.6;
            double frequency = 520 + 300 * (0.5 - 0.5 * Math.Cos(2 * Math.PI * cycle / 0.6));
            phase += 2 * Math.PI * frequency / sampleRate;
            double envelope = Math.Min(1, Math.Min(cycle / 0.05, (0.6 - cycle) / 0.1));
            writer.Write((short)(Math.Sin(phase) * Math.Max(0, envelope) * 0.14 * short.MaxValue));
        }

        return stream.ToArray();
    }

    public void Dispose()
    {
        Stop();
        _player?.Dispose();
        _stream.Dispose();
    }
}
