using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace WindowsCleanup
{
    [ComImport]
    [Guid("43826d1e-e718-42ee-bc55-a1e261c37bfe")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IShellItem
    {
        void BindToHandler(IntPtr pbc, ref Guid bhid, ref Guid riid, out IntPtr ppv);
        void GetParent(out IShellItem ppsi);
        void GetDisplayName(uint sigdnName, out IntPtr ppszName);
        void GetAttributes(uint sfgaoMask, out uint psfgaoAttribs);
        void Compare(IShellItem psi, uint hint, out int piOrder);
    }

    [ComImport]
    [Guid("947aab5f-0a5c-4c13-b4d6-4bf7836fc9f8")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IFileOperation
    {
        void Advise(IProgress pfops, out uint pdwCookie);
        void Unadvise(uint dwCookie);
        void SetOperationFlags(uint dwOperationFlags);
        void SetProgressMessage([MarshalAs(UnmanagedType.LPWStr)] string pszMessage);
        void SetProgressDialog(IntPtr popd);
        void SetProperties(IntPtr pproparray);
        void SetOwnerWindow(uint hwndOwner);
        void ApplyPropertiesToItem(IShellItem psiItem);
        void ApplyPropertiesToItems(IntPtr punkItems);
        void RenameItem(IShellItem psiItem, [MarshalAs(UnmanagedType.LPWStr)] string pszNewName, IProgress pfopsItem);
        void RenameItems(IntPtr pUnkItems, [MarshalAs(UnmanagedType.LPWStr)] string pszNewName);
        void MoveItem(IShellItem psiItem, IShellItem psiDestinationFolder, [MarshalAs(UnmanagedType.LPWStr)] string pszNewName, IProgress pfopsItem);
        void MoveItems(IntPtr punkItems, IShellItem psiDestinationFolder);
        void CopyItem(IShellItem psiItem, IShellItem psiDestinationFolder, [MarshalAs(UnmanagedType.LPWStr)] string pszCopyName, IProgress pfopsItem);
        void CopyItems(IntPtr punkItems, IShellItem psiDestinationFolder);
        void DeleteItem(IShellItem psiItem, IProgress pfopsItem);
        void DeleteItems(IntPtr punkItems);
        void NewItem(IShellItem psiDestinationFolder, uint dwFileAttributes, [MarshalAs(UnmanagedType.LPWStr)] string pszName, [MarshalAs(UnmanagedType.LPWStr)] string pszTemplateName, IProgress pfopsItem);
        void PerformOperations();
        void GetAnyOperationsAborted([MarshalAs(UnmanagedType.Bool)] out bool pfAnyOperationsAborted);
    }

    [ComVisible(true)]
    [Guid("04b0f1a7-9490-44bc-96e1-4296a31252e2")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IProgress
    {
        [PreserveSig] int StartOperations();
        [PreserveSig] int FinishOperations(int hrResult);
        [PreserveSig] int PreRenameItem(uint dwFlags, IShellItem psiItem, [MarshalAs(UnmanagedType.LPWStr)] string pszNewName);
        [PreserveSig] int PostRenameItem(uint dwFlags, IShellItem psiItem, [MarshalAs(UnmanagedType.LPWStr)] string pszNewName, int hrRename, IShellItem psiNewlyCreated);
        [PreserveSig] int PreMoveItem(uint dwFlags, IShellItem psiItem, IShellItem psiDestinationFolder, [MarshalAs(UnmanagedType.LPWStr)] string pszNewName);
        [PreserveSig] int PostMoveItem(uint dwFlags, IShellItem psiItem, IShellItem psiDestinationFolder, [MarshalAs(UnmanagedType.LPWStr)] string pszNewName, int hrMove, IShellItem psiNewlyCreated);
        [PreserveSig] int PreCopyItem(uint dwFlags, IShellItem psiItem, IShellItem psiDestinationFolder, [MarshalAs(UnmanagedType.LPWStr)] string pszNewName);
        [PreserveSig] int PostCopyItem(uint dwFlags, IShellItem psiItem, IShellItem psiDestinationFolder, [MarshalAs(UnmanagedType.LPWStr)] string pszNewName, int hrCopy, IShellItem psiNewlyCreated);
        [PreserveSig] int PreDeleteItem(uint dwFlags, IShellItem psiItem);
        [PreserveSig] int PostDeleteItem(uint dwFlags, IShellItem psiItem, int hrDelete, IShellItem psiNewlyCreated);
        [PreserveSig] int PreNewItem(uint dwFlags, IShellItem psiDestinationFolder, [MarshalAs(UnmanagedType.LPWStr)] string pszNewName);
        [PreserveSig] int PostNewItem(uint dwFlags, IShellItem psiDestinationFolder, [MarshalAs(UnmanagedType.LPWStr)] string pszNewName, [MarshalAs(UnmanagedType.LPWStr)] string pszTemplateName, uint dwFileAttributes, int hrNew, IShellItem psiNewItem);
        [PreserveSig] int UpdateProgress(uint iWorkTotal, uint iWorkSoFar);
        [PreserveSig] int ResetTimer();
        [PreserveSig] int PauseTimer();
        [PreserveSig] int ResumeTimer();
    }

    [ComVisible(true)]
    [ClassInterface(ClassInterfaceType.None)]
    public sealed class RecycleSink : IProgress
    {
        private const int E_ABORT = unchecked((int)0x80004004);
        private const uint TSF_DELETE_RECYCLE_IF_POSSIBLE = 0x0080u;
        private const uint SIGDN_FILESYSPATH = 0x80058000u;

        public bool PreSeen;
        public bool PostSeen;
        public bool Recycled;
        public int DeleteResult;
        public string RecycledPath;

        public int StartOperations() => 0;
        public int FinishOperations(int hrResult) => 0;

        public int PreRenameItem(uint dwFlags, IShellItem psiItem, string pszNewName) => E_ABORT;
        public int PostRenameItem(uint dwFlags, IShellItem psiItem, string pszNewName, int hrRename, IShellItem psiNewlyCreated) => 0;

        public int PreMoveItem(uint dwFlags, IShellItem psiItem, IShellItem psiDestinationFolder, string pszNewName) => E_ABORT;
        public int PostMoveItem(uint dwFlags, IShellItem psiItem, IShellItem psiDestinationFolder, string pszNewName, int hrMove, IShellItem psiNewlyCreated) => 0;

        public int PreCopyItem(uint dwFlags, IShellItem psiItem, IShellItem psiDestinationFolder, string pszNewName) => E_ABORT;
        public int PostCopyItem(uint dwFlags, IShellItem psiItem, IShellItem psiDestinationFolder, string pszNewName, int hrCopy, IShellItem psiNewlyCreated) => 0;

        // 回调未声明可回收时立即取消；之后的永久删除警告由 FOF_WANTNUKEWARNING 保留。
        public int PreDeleteItem(uint dwFlags, IShellItem psiItem)
        {
            PreSeen = true;
            return (dwFlags & TSF_DELETE_RECYCLE_IF_POSSIBLE) != 0 ? 0 : E_ABORT;
        }

        public int PostDeleteItem(uint dwFlags, IShellItem psiItem, int hrDelete, IShellItem psiNewlyCreated)
        {
            PostSeen = true;
            DeleteResult = hrDelete;
            Recycled = hrDelete >= 0 && psiNewlyCreated != null;

            if (Recycled)
            {
                try
                {
                    IntPtr ptr;
                    psiNewlyCreated.GetDisplayName(SIGDN_FILESYSPATH, out ptr);
                    try
                    {
                        RecycledPath = Marshal.PtrToStringUni(ptr);
                    }
                    finally
                    {
                        Marshal.FreeCoTaskMem(ptr);
                    }
                }
                catch
                {
                }
            }

            return Recycled ? 0 : E_ABORT;
        }

        public int PreNewItem(uint dwFlags, IShellItem psiDestinationFolder, string pszNewName) => E_ABORT;
        public int PostNewItem(uint dwFlags, IShellItem psiDestinationFolder, string pszNewName, string pszTemplateName, uint dwFileAttributes, int hrNew, IShellItem psiNewItem) => 0;

        public int UpdateProgress(uint iWorkTotal, uint iWorkSoFar) => 0;
        public int ResetTimer() => 0;
        public int PauseTimer() => 0;
        public int ResumeTimer() => 0;
    }

    public sealed class RecycleResult
    {
        public bool Success;
        public string RecycledPath;
        public string Error;
        public int HResult;
    }

    public static class Recycle
    {
        private const uint FOF_SILENT = 0x0004u;
        private const uint FOF_NOCONFIRMATION = 0x0010u;
        private const uint FOF_NOERRORUI = 0x0400u;
        private const uint FOF_NO_CONNECTED_ELEMENTS = 0x2000u;
        private const uint FOF_WANTNUKEWARNING = 0x4000u;
        private const uint FOFX_RECYCLEONDELETE = 0x00080000u;
        private const uint FOFX_EARLYFAILURE = 0x00100000u;

        // 永久删除警告优先于普通自动确认；调用方不得接受该警告。
        public const uint OperationFlags =
            FOF_SILENT |
            FOF_NOCONFIRMATION |
            FOF_NOERRORUI |
            FOF_NO_CONNECTED_ELEMENTS |
            FOF_WANTNUKEWARNING |
            FOFX_RECYCLEONDELETE |
            FOFX_EARLYFAILURE;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint QueryDosDevice(string lpDeviceName, StringBuilder lpTargetPath, int ucchMax);

        [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
        private static extern void SHCreateItemFromParsingName(string pszPath, IntPtr pbc, ref Guid riid, out IShellItem ppv);

        public static bool IsDirectVolume(string drive)
        {
            var buffer = new StringBuilder(32768);
            if (QueryDosDevice(drive, buffer, buffer.Capacity) == 0)
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }

            return buffer.ToString().StartsWith(@"\Device\HarddiskVolume", StringComparison.OrdinalIgnoreCase);
        }

        public static RecycleResult One(string path)
        {
            var result = new RecycleResult();

            // IFileOperation 在专用 STA 线程执行；调用者可以运行在 PowerShell 默认的 MTA。
            var thread = new Thread(() =>
            {
                IFileOperation operation = null;
                IShellItem item = null;
                try
                {
                    var clsid = new Guid("3ad05575-8857-4850-9277-11b85bdb8e09");
                    operation = (IFileOperation)Activator.CreateInstance(Type.GetTypeFromCLSID(clsid));

                    // 普通回收不确认、不提权、出错立即终止、不扩展关联文件；保留永久删除警告。
                    operation.SetOperationFlags(OperationFlags);

                    Guid iid = typeof(IShellItem).GUID;
                    SHCreateItemFromParsingName(path, IntPtr.Zero, ref iid, out item);

                    var sink = new RecycleSink();
                    operation.DeleteItem(item, sink);
                    operation.PerformOperations();

                    bool aborted;
                    operation.GetAnyOperationsAborted(out aborted);

                    result.Success =
                        !aborted &&
                        sink.PreSeen &&
                        sink.PostSeen &&
                        sink.Recycled &&
                        !File.Exists(path) &&
                        !Directory.Exists(path);
                    result.RecycledPath = sink.RecycledPath;
                    result.HResult = sink.DeleteResult;

                    if (!result.Success)
                    {
                        result.Error = "回收未获完整确认；操作可能取消或失败。停止后续目标，不执行永久删除。";
                    }

                    GC.KeepAlive(sink);
                }
                catch (Exception ex)
                {
                    result.Error = ex.Message;
                    result.HResult = ex.HResult;
                }
                finally
                {
                    if (item != null)
                    {
                        Marshal.ReleaseComObject(item);
                    }
                    if (operation != null)
                    {
                        Marshal.ReleaseComObject(operation);
                    }
                }
            });

            thread.SetApartmentState(ApartmentState.STA);
            thread.Start();
            thread.Join();
            return result;
        }
    }
}
