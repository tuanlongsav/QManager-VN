"use client";

import SmsInboxCard from "./sms-inbox-card";
import { useSms } from "@/hooks/use-sms";
import { useT } from "@/hooks/use-i18n";

const SmsCenterComponent = () => {
  const { t } = useT();
  const {
    data,
    outbox,
    isLoading,
    isSaving,
    error,
    sendSms,
    deleteSms,
    deleteAllSms,
    refresh,
  } = useSms();

  return (
    <div className="@container/main mx-auto p-2">
      <div className="mb-6">
        <h1 className="text-3xl font-bold mb-2">{t("smsCenter.heading")}</h1>
        <p className="text-muted-foreground">{t("smsCenter.description")}</p>
      </div>
      <div className="grid grid-cols-1 grid-flow-row gap-4">
        <SmsInboxCard
          data={data}
          outbox={outbox}
          isLoading={isLoading}
          isSaving={isSaving}
          error={error}
          onSend={sendSms}
          onDelete={deleteSms}
          onDeleteAll={deleteAllSms}
          onRefresh={() => refresh()}
        />
      </div>
    </div>
  );
};

export default SmsCenterComponent;
