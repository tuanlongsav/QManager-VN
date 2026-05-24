"use client";

import * as React from "react";
import { motion } from "motion/react";
import {
  flexRender,
  getCoreRowModel,
  getPaginationRowModel,
  useReactTable,
  type ColumnDef,
  type RowSelectionState,
} from "@tanstack/react-table";
import {
  TbDotsVertical,
  TbEye,
  TbTrash,
  TbRefresh,
  TbPlus,
} from "react-icons/tb";
import { AlertCircleIcon, Loader2, Trash2 } from "lucide-react";
import { toast } from "sonner";

import { Button } from "@/components/ui/button";
import {
  Card,
  CardAction,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import {
  Tabs,
  TabsList,
  TabsTrigger,
} from "@/components/ui/tabs";

const MotionTableRow = motion.create(TableRow);
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog";
import { Checkbox } from "@/components/ui/checkbox";
import { Skeleton } from "@/components/ui/skeleton";
import { Badge } from "@/components/ui/badge";

import type { SmsData, SmsFolder } from "@/hooks/use-sms";
import type { SmsMessage } from "@/types/sms";
import {
  classifySender,
  formatSenderDisplay,
  isKnownVnBrand,
} from "@/lib/sms-format";
import SmsComposeDialog from "./sms-compose-dialog";
import { useT } from "@/hooks/use-i18n";

// =============================================================================
// SmsInboxCard — Displays SMS messages in a tabbed Inbox/Outbox card
// =============================================================================

interface SmsInboxCardProps {
  data: SmsData | null;
  outbox: SmsData | null;
  isLoading: boolean;
  isSaving: boolean;
  /** Error from the hook (fetch or mutation failure) */
  error: string | null;
  onSend: (phone: string, message: string) => Promise<boolean>;
  onDelete: (indexes: number[], folder?: SmsFolder) => Promise<boolean>;
  onDeleteAll: (folder?: SmsFolder) => Promise<boolean>;
  onRefresh: () => void;
}

export default function SmsInboxCard({
  data,
  outbox,
  isLoading,
  isSaving,
  error,
  onSend,
  onDelete,
  onDeleteAll,
  onRefresh,
}: SmsInboxCardProps) {
  const { t } = useT();
  const [folder, setFolder] = React.useState<SmsFolder>("inbox");
  const [viewMessage, setViewMessage] = React.useState<SmsMessage | null>(null);
  const [deleteTarget, setDeleteTarget] = React.useState<SmsMessage | null>(
    null,
  );
  const [showDeleteAll, setShowDeleteAll] = React.useState(false);
  const [showDeleteSelected, setShowDeleteSelected] = React.useState(false);
  const [isDeleting, setIsDeleting] = React.useState(false);
  const [showCompose, setShowCompose] = React.useState(false);
  const [rowSelection, setRowSelection] = React.useState<RowSelectionState>({});

  // Reset selection when switching folder so the action buttons reflect the
  // current view.
  React.useEffect(() => {
    setRowSelection({});
  }, [folder]);

  const isOutbox = folder === "outbox";
  const activeData = isOutbox ? outbox : data;

  const handleDelete = async () => {
    if (!deleteTarget) return;
    setIsDeleting(true);
    const success = await onDelete(deleteTarget.indexes, folder);
    setIsDeleting(false);
    setDeleteTarget(null);
    if (success) {
      toast.success(t("smsCenter.toastDeleted"));
    } else {
      toast.error(t("smsCenter.toastDeleteFailed"));
    }
  };

  const handleDeleteAll = async () => {
    setIsDeleting(true);
    const success = await onDeleteAll(folder);
    setIsDeleting(false);
    setShowDeleteAll(false);
    setRowSelection({});
    if (success) {
      toast.success(t("smsCenter.toastDeletedAll"));
    } else {
      toast.error(t("smsCenter.toastDeleteAllFailed"));
    }
  };

  const handleDeleteSelected = async () => {
    const selectedRows = table.getSelectedRowModel().rows;
    if (selectedRows.length === 0) return;

    setIsDeleting(true);
    // Collect all indexes from all selected messages
    const allIndexes = selectedRows.flatMap((row) => row.original.indexes);
    const success = await onDelete(allIndexes, folder);
    setIsDeleting(false);
    setShowDeleteSelected(false);
    setRowSelection({});
    if (success) {
      toast.success(
        t("smsCenter.toastDeletedSelected", { count: selectedRows.length }),
      );
    } else {
      toast.error(t("smsCenter.toastDeleteSelectedFailed"));
    }
  };

  const selectedCount = Object.keys(rowSelection).length;

  const columns: ColumnDef<SmsMessage>[] = React.useMemo(
    () => [
      {
        id: "select",
        header: ({ table: tbl }) => (
          <div onClick={(e) => e.stopPropagation()}>
            <Checkbox
              checked={
                tbl.getIsAllPageRowsSelected() ||
                (tbl.getIsSomePageRowsSelected() && "indeterminate")
              }
              onCheckedChange={(value) =>
                tbl.toggleAllPageRowsSelected(!!value)
              }
              aria-label={t("smsCenter.selectAll")}
            />
          </div>
        ),
        cell: ({ row }) => (
          <div onClick={(e) => e.stopPropagation()}>
            <Checkbox
              checked={row.getIsSelected()}
              onCheckedChange={(value) => row.toggleSelected(!!value)}
              aria-label={t("smsCenter.selectRow")}
            />
          </div>
        ),
        enableSorting: false,
        enableHiding: false,
      },
      {
        accessorKey: "sender",
        header: isOutbox ? t("smsCenter.columnTo") : t("smsCenter.columnFrom"),
        cell: ({ row }) => {
          const raw = row.original.sender;
          const display = formatSenderDisplay(raw);
          const kind = classifySender(raw);
          return (
            <div className="min-w-0">
              <div className="flex items-center gap-1.5 min-w-0">
                <span className="font-medium truncate">{display}</span>
                {!isOutbox && kind === "brand" && (
                  <Badge
                    variant="outline"
                    className="bg-info/15 text-info border-info/30 text-[10px] px-1.5 py-0 h-4 shrink-0"
                    title={
                      isKnownVnBrand(raw)
                        ? t("smsCenter.vnBrandTooltip")
                        : t("smsCenter.brandTooltip")
                    }
                  >
                    {isKnownVnBrand(raw) ? t("smsCenter.vnBrand") : t("smsCenter.brand")}
                  </Badge>
                )}
              </div>
              <span className="block text-xs text-muted-foreground @sm/card:hidden">
                {row.original.timestamp}
              </span>
            </div>
          );
        },
      },
      {
        accessorKey: "content",
        header: () => (
          <span className="hidden @md/card:inline">{t("smsCenter.columnMessage")}</span>
        ),
        cell: ({ row }) => (
          <div className="hidden @md/card:block max-w-xs truncate text-muted-foreground">
            {row.original.content}
          </div>
        ),
      },
      {
        id: "date",
        header: () => (
          <span className="hidden @sm/card:inline">{t("smsCenter.columnDate")}</span>
        ),
        cell: ({ row }) => (
          <span className="hidden @sm/card:inline text-muted-foreground text-sm whitespace-nowrap">
            {row.original.timestamp}
          </span>
        ),
      },
      {
        id: "actions",
        header: "",
        cell: ({ row }) => (
          <div onClick={(e) => e.stopPropagation()}>
            <DropdownMenu>
              <DropdownMenuTrigger asChild>
                <Button
                  variant="ghost"
                  className="data-[state=open]:bg-muted text-muted-foreground flex size-8"
                  size="icon"
                >
                  <TbDotsVertical />
                  <span className="sr-only">{t("smsCenter.openMenu")}</span>
                </Button>
              </DropdownMenuTrigger>
              <DropdownMenuContent align="end" className="w-40">
                <DropdownMenuItem onClick={() => setViewMessage(row.original)}>
                  <TbEye className="size-4" />
                  {t("smsCenter.view")}
                </DropdownMenuItem>
                <DropdownMenuSeparator />
                <DropdownMenuItem
                  variant="destructive"
                  onClick={() => setDeleteTarget(row.original)}
                >
                  <TbTrash className="size-4" />
                  {t("smsCenter.delete")}
                </DropdownMenuItem>
              </DropdownMenuContent>
            </DropdownMenu>
          </div>
        ),
      },
    ],
    [isOutbox, t],
  );

  const table = useReactTable({
    data: activeData?.messages ?? [],
    columns,
    getCoreRowModel: getCoreRowModel(),
    getPaginationRowModel: getPaginationRowModel(),
    onRowSelectionChange: setRowSelection,
    state: {
      rowSelection,
    },
    initialState: {
      pagination: { pageSize: 10 },
    },
  });

  // --- Loading state ---------------------------------------------------------
  if (isLoading) {
    return (
      <Card>
        <CardHeader>
          <CardTitle>
            <Skeleton className="h-5 w-20" />
          </CardTitle>
          <CardDescription>
            <Skeleton className="h-4 w-48" />
          </CardDescription>
        </CardHeader>
        <CardContent>
          <div className="space-y-3">
            {Array.from({ length: 5 }).map((_, i) => (
              <Skeleton key={i} className="h-10 w-full" />
            ))}
          </div>
        </CardContent>
      </Card>
    );
  }

  // --- Error state (fetch failed, no data) ----------------------------------
  if (error && !data && !outbox) {
    return (
      <Card>
        <CardHeader>
          <CardTitle>{t("smsCenter.inboxTitle")}</CardTitle>
          <CardDescription>{t("smsCenter.inboxDescription")}</CardDescription>
        </CardHeader>
        <CardContent>
          <div
            role="alert"
            className="flex flex-col items-center gap-3 py-8 text-center"
          >
            <AlertCircleIcon className="size-8 text-destructive" />
            <div className="space-y-1">
              <p className="text-sm font-medium">{t("smsCenter.failedToLoad")}</p>
              <p className="text-xs text-muted-foreground">{error}</p>
            </div>
            <Button variant="outline" size="sm" onClick={onRefresh}>
              <TbRefresh className="size-4" />
              {t("smsCenter.retry")}
            </Button>
          </div>
        </CardContent>
      </Card>
    );
  }

  const messages = activeData?.messages ?? [];
  const storage = data?.storage;

  const cardTitle = isOutbox ? t("smsCenter.outboxTitle") : t("smsCenter.inboxTitle");
  const cardDescription = isOutbox
    ? t("smsCenter.outboxDescription")
    : storage
    ? t("smsCenter.inboxDescriptionWithCount", {
        used: storage.used,
        total: storage.total,
      })
    : t("smsCenter.inboxDescription");

  return (
    <>
      <Card className="@container/card">
        <CardHeader>
          <CardTitle>{cardTitle}</CardTitle>
          <CardDescription>{cardDescription}</CardDescription>
          <CardAction>
            <div className="flex items-center gap-2">
              <Button
                variant="outline"
                size="sm"
                onClick={onRefresh}
                disabled={isSaving}
                aria-label={t("smsCenter.refreshAria")}
              >
                <TbRefresh className="size-4" />
              </Button>
              {selectedCount > 0 && (
                <Button
                  variant="destructive"
                  size="sm"
                  onClick={() => setShowDeleteSelected(true)}
                  disabled={isSaving}
                  aria-label={t("smsCenter.deleteSelectedAria", { count: selectedCount })}
                >
                  <Trash2 className="size-4" />
                  <span className="hidden @sm/card:inline">
                    {t("smsCenter.deleteSelected", { count: selectedCount })}
                  </span>
                </Button>
              )}
              {messages.length > 0 && selectedCount === 0 && (
                <Button
                  variant="destructive"
                  size="sm"
                  onClick={() => setShowDeleteAll(true)}
                  disabled={isSaving}
                  aria-label={t("smsCenter.deleteAllAria")}
                >
                  <Trash2 className="size-4" />
                  <span className="hidden @sm/card:inline">{t("smsCenter.deleteAll")}</span>
                </Button>
              )}
              <Button
                size="sm"
                onClick={() => setShowCompose(true)}
                disabled={isSaving}
              >
                <TbPlus className="size-4" />
                <span className="hidden @xs/card:inline">{t("smsCenter.newMessage")}</span>
              </Button>
            </div>
          </CardAction>
        </CardHeader>
        <CardContent>
          <Tabs value={folder} onValueChange={(v) => setFolder(v as SmsFolder)} className="mb-3">
            <TabsList>
              <TabsTrigger value="inbox">{t("smsCenter.inboxTab")}</TabsTrigger>
              <TabsTrigger value="outbox">{t("smsCenter.outboxTab")}</TabsTrigger>
            </TabsList>
          </Tabs>
          <div className="overflow-hidden rounded-lg border">
            <Table>
              <TableHeader className="bg-muted sticky top-0 z-10">
                {table.getHeaderGroups().map((headerGroup) => (
                  <TableRow key={headerGroup.id}>
                    {headerGroup.headers.map((header) => (
                      <TableHead key={header.id} colSpan={header.colSpan}>
                        {header.isPlaceholder
                          ? null
                          : flexRender(
                              header.column.columnDef.header,
                              header.getContext(),
                            )}
                      </TableHead>
                    ))}
                  </TableRow>
                ))}
              </TableHeader>
              <TableBody>
                {table.getRowModel().rows?.length ? (
                  table.getRowModel().rows.map((row, index) => (
                    <MotionTableRow
                      key={row.id}
                      className="cursor-pointer"
                      tabIndex={0}
                      aria-label={
                        isOutbox
                          ? t("smsCenter.messageTo", {
                              recipient: formatSenderDisplay(row.original.sender),
                            })
                          : t("smsCenter.messageFrom", {
                              sender: formatSenderDisplay(row.original.sender),
                            })
                      }
                      onClick={() => setViewMessage(row.original)}
                      onKeyDown={(e) => {
                        if (e.key === "Enter" || e.key === " ") {
                          e.preventDefault();
                          setViewMessage(row.original);
                        }
                      }}
                      initial={{ opacity: 0, x: -8 }}
                      animate={{ opacity: 1, x: 0 }}
                      transition={{ duration: 0.2, delay: Math.min(index * 0.04, 0.4), ease: "easeOut" }}
                    >
                      {row.getVisibleCells().map((cell) => (
                        <TableCell key={cell.id}>
                          {flexRender(
                            cell.column.columnDef.cell,
                            cell.getContext(),
                          )}
                        </TableCell>
                      ))}
                    </MotionTableRow>
                  ))
                ) : (
                  <TableRow>
                    <TableCell
                      colSpan={columns.length}
                      className="h-24 text-center"
                    >
                      {t("smsCenter.noMessages")}
                    </TableCell>
                  </TableRow>
                )}
              </TableBody>
            </Table>
          </div>

          {messages.length > 0 && (
            <div className="flex items-center justify-between px-2 pt-2">
              <span className="text-muted-foreground text-sm">
                {t("smsCenter.messageCount", { count: messages.length })}
              </span>
              {table.getPageCount() > 1 && (
                <div className="flex items-center gap-2">
                  <Button
                    variant="outline"
                    size="sm"
                    onClick={() => table.previousPage()}
                    disabled={!table.getCanPreviousPage()}
                  >
                    {t("smsCenter.prev")}
                  </Button>
                  <span className="text-sm text-muted-foreground whitespace-nowrap">
                    {table.getState().pagination.pageIndex + 1} / {table.getPageCount()}
                  </span>
                  <Button
                    variant="outline"
                    size="sm"
                    onClick={() => table.nextPage()}
                    disabled={!table.getCanNextPage()}
                  >
                    {t("smsCenter.next")}
                  </Button>
                </div>
              )}
            </div>
          )}
        </CardContent>
      </Card>

      {/* View Message Dialog */}
      <Dialog
        open={!!viewMessage}
        onOpenChange={(open) => !open && setViewMessage(null)}
      >
        <DialogContent className="sm:max-w-lg">
          <DialogHeader>
            <DialogTitle>
              {isOutbox
                ? t("smsCenter.messageTo", {
                    recipient: formatSenderDisplay(viewMessage?.sender),
                  })
                : t("smsCenter.messageFrom", {
                    sender: formatSenderDisplay(viewMessage?.sender),
                  })}
            </DialogTitle>
            <DialogDescription>{viewMessage?.timestamp}</DialogDescription>
          </DialogHeader>
          <div className="whitespace-pre-wrap wrap-break-word text-sm">
            {viewMessage?.content}
          </div>
        </DialogContent>
      </Dialog>

      {/* Delete Single Confirmation */}
      <AlertDialog
        open={!!deleteTarget}
        onOpenChange={(open) => !open && setDeleteTarget(null)}
      >
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>{t("smsCenter.deleteMessageTitle")}</AlertDialogTitle>
            <AlertDialogDescription>
              {isOutbox
                ? t("smsCenter.deleteOutboxConfirm", {
                    recipient: formatSenderDisplay(deleteTarget?.sender),
                  })
                : t("smsCenter.deleteMessageConfirm", {
                    sender: formatSenderDisplay(deleteTarget?.sender),
                  })}
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel disabled={isDeleting}>{t("common.cancel")}</AlertDialogCancel>
            <AlertDialogAction
              onClick={handleDelete}
              disabled={isDeleting}
              className="bg-destructive text-destructive-foreground hover:bg-destructive/90"
            >
              {isDeleting ? (
                <>
                  <Loader2 className="size-4 animate-spin" />
                  {t("smsCenter.deleting")}
                </>
              ) : (
                t("smsCenter.delete")
              )}
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>

      {/* Delete All Confirmation */}
      <AlertDialog
        open={showDeleteAll}
        onOpenChange={(open) => !open && setShowDeleteAll(false)}
      >
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>{t("smsCenter.deleteAllTitle")}</AlertDialogTitle>
            <AlertDialogDescription>
              {t("smsCenter.deleteAllConfirm", { count: messages.length })}
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel disabled={isDeleting}>{t("common.cancel")}</AlertDialogCancel>
            <AlertDialogAction
              onClick={handleDeleteAll}
              disabled={isDeleting}
              className="bg-destructive text-destructive-foreground hover:bg-destructive/90"
            >
              {isDeleting ? (
                <>
                  <Loader2 className="size-4 animate-spin" />
                  {t("smsCenter.deleting")}
                </>
              ) : (
                t("smsCenter.deleteAll")
              )}
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>

      {/* Delete Selected Confirmation */}
      <AlertDialog
        open={showDeleteSelected}
        onOpenChange={(open) => !open && setShowDeleteSelected(false)}
      >
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>{t("smsCenter.deleteSelectedTitle")}</AlertDialogTitle>
            <AlertDialogDescription>
              {t("smsCenter.deleteSelectedConfirm", { count: selectedCount })}
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel disabled={isDeleting}>{t("common.cancel")}</AlertDialogCancel>
            <AlertDialogAction
              onClick={handleDeleteSelected}
              disabled={isDeleting}
              className="bg-destructive text-destructive-foreground hover:bg-destructive/90"
            >
              {isDeleting ? (
                <>
                  <Loader2 className="size-4 animate-spin" />
                  {t("smsCenter.deleting")}
                </>
              ) : (
                t("smsCenter.deleteSelected", { count: selectedCount })
              )}
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>

      {/* Compose Dialog */}
      <SmsComposeDialog
        open={showCompose}
        onOpenChange={setShowCompose}
        onSend={onSend}
        isSaving={isSaving}
      />
    </>
  );
}
