using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace TerminalAutoTheme
{
    // Attaches to another process's console (works for ConPTY-hosted apps inside Windows Terminal)
    // to type keystrokes into it and read its visible screen text.
    public static class ConsoleInput
    {
        const uint GENERIC_READ = 0x80000000, GENERIC_WRITE = 0x40000000;
        const uint FILE_SHARE_READ = 1, FILE_SHARE_WRITE = 2, OPEN_EXISTING = 3;
        const ushort KEY_EVENT = 1;
        static readonly IntPtr INVALID_HANDLE = new IntPtr(-1);

        [StructLayout(LayoutKind.Explicit, CharSet = CharSet.Unicode)]
        struct INPUT_RECORD
        {
            [FieldOffset(0)] public ushort EventType;
            [FieldOffset(4)] public int bKeyDown;
            [FieldOffset(8)] public ushort wRepeatCount;
            [FieldOffset(10)] public ushort wVirtualKeyCode;
            [FieldOffset(12)] public ushort wVirtualScanCode;
            [FieldOffset(14)] public char UnicodeChar;
            [FieldOffset(16)] public uint dwControlKeyState;
        }

        [StructLayout(LayoutKind.Sequential)] struct COORD { public short X, Y; }
        [StructLayout(LayoutKind.Sequential)] struct SMALL_RECT { public short Left, Top, Right, Bottom; }
        [StructLayout(LayoutKind.Sequential)]
        struct CONSOLE_SCREEN_BUFFER_INFO { public COORD dwSize, dwCursorPosition; public ushort wAttributes; public SMALL_RECT srWindow; public COORD dwMaximumWindowSize; }

        [DllImport("kernel32.dll", SetLastError = true)] static extern bool FreeConsole();
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool AttachConsole(uint pid);
        [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr GetConsoleWindow();
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr sa, uint disp, uint flags, IntPtr tmpl);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern bool WriteConsoleInputW(IntPtr h, INPUT_RECORD[] recs, uint len, out uint written);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool GetConsoleScreenBufferInfo(IntPtr h, out CONSOLE_SCREEN_BUFFER_INFO info);
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern bool ReadConsoleOutputCharacterW(IntPtr h, StringBuilder buf, uint len, COORD at, out uint read);
        [DllImport("user32.dll")] static extern short VkKeyScanW(char ch);
        [DllImport("user32.dll")] static extern uint MapVirtualKeyW(uint code, uint mapType);

        // Serializes attach/detach because a process can only be attached to one console at a time.
        static readonly object Gate = new object();

        static T WithConsole<T>(int pid, string device, Func<IntPtr, T> action)
        {
            lock (Gate)
            {
                FreeConsole();
                if (!AttachConsole((uint)pid)) throw new Win32Exception(Marshal.GetLastWin32Error(), "AttachConsole(" + pid + ") failed");
                IntPtr h = INVALID_HANDLE;
                try
                {
                    h = CreateFileW(device, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
                    if (h == INVALID_HANDLE) throw new Win32Exception(Marshal.GetLastWin32Error(), "Open " + device + " failed");
                    return action(h);
                }
                finally
                {
                    if (h != INVALID_HANDLE) CloseHandle(h);
                    FreeConsole();
                }
            }
        }

        // Returns an identifier that is shared by all processes attached to the same console.
        public static long GetConsoleId(int pid)
        {
            return WithConsole(pid, "CONIN$", h => GetConsoleWindow().ToInt64());
        }

        static void AddKey(List<INPUT_RECORD> recs, char ch, ushort vk)
        {
            ushort scan = (ushort)MapVirtualKeyW(vk, 0);
            foreach (int down in new[] { 1, 0 })
                recs.Add(new INPUT_RECORD { EventType = KEY_EVENT, bKeyDown = down, wRepeatCount = 1, wVirtualKeyCode = vk, wVirtualScanCode = scan, UnicodeChar = ch });
        }

        public static void SendText(int pid, string text)
        {
            var recs = new List<INPUT_RECORD>();
            foreach (char ch in text)
            {
                short vks = VkKeyScanW(ch);
                AddKey(recs, ch, vks == -1 ? (ushort)0 : (ushort)(vks & 0xFF));
            }
            Write(pid, recs);
        }

        public static void SendEnter(int pid)
        {
            var recs = new List<INPUT_RECORD>();
            AddKey(recs, '\r', 0x0D);
            Write(pid, recs);
        }

        static void Write(int pid, List<INPUT_RECORD> recs)
        {
            WithConsole(pid, "CONIN$", h =>
            {
                uint written;
                if (!WriteConsoleInputW(h, recs.ToArray(), (uint)recs.Count, out written))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "WriteConsoleInput failed");
                return written;
            });
        }

        // Visible window rows of the console, one string per row.
        public static string[] ReadScreen(int pid)
        {
            return WithConsole(pid, "CONOUT$", h =>
            {
                CONSOLE_SCREEN_BUFFER_INFO info;
                if (!GetConsoleScreenBufferInfo(h, out info)) throw new Win32Exception(Marshal.GetLastWin32Error(), "GetConsoleScreenBufferInfo failed");
                int width = info.srWindow.Right - info.srWindow.Left + 1;
                var rows = new List<string>();
                for (short y = info.srWindow.Top; y <= info.srWindow.Bottom; y++)
                {
                    var sb = new StringBuilder(width);
                    uint read;
                    ReadConsoleOutputCharacterW(h, sb, (uint)width, new COORD { X = info.srWindow.Left, Y = y }, out read);
                    rows.Add(sb.ToString(0, Math.Min((int)read, sb.Length)).TrimEnd());
                }
                return rows.ToArray();
            });
        }
    }
}
