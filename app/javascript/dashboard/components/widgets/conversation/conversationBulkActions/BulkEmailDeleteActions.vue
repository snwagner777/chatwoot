<script setup>
import { computed, ref } from 'vue';
import { useStore } from 'vuex';
import { useI18n } from 'vue-i18n';
import { useMapGetter } from 'dashboard/composables/store';
import { useAdmin } from 'dashboard/composables/useAdmin';
import { useAlert } from 'dashboard/composables';
import BulkActionsAPI from 'dashboard/api/bulkActions';
import Button from 'dashboard/components-next/button/Button.vue';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';

const props = defineProps({
  conversationIds: { type: Array, required: true },
  inboxIds: { type: Array, required: true },
});

const { t } = useI18n();
const store = useStore();
const { isAdmin } = useAdmin();
const getInbox = useMapGetter('getInbox');
const dialog = ref(null);
const mode = ref('trash');
const confirmation = ref('');
const loading = ref(false);
const failures = ref([]);

const available = computed(
  () =>
    isAdmin.value &&
    props.conversationIds.length > 0 &&
    props.inboxIds.length > 0 &&
    props.inboxIds.every(
      id => getInbox.value(id).channel_type === 'Channel::Email'
    )
);
const canConfirm = computed(
  () =>
    !loading.value &&
    props.conversationIds.length <= 25 &&
    (mode.value !== 'permanent' || confirmation.value === 'DELETE PERMANENTLY')
);

const open = requestedMode => {
  mode.value = requestedMode;
  confirmation.value = '';
  failures.value = [];
  dialog.value?.open();
};

const deleteEmails = async () => {
  if (!canConfirm.value) return;

  loading.value = true;
  try {
    const { data } = await BulkActionsAPI.deleteEmailConversations({
      ids: [...props.conversationIds],
      mode: mode.value,
      confirmation: confirmation.value,
    });
    failures.value = data.results.filter(result => result.error);
    if (failures.value.length) {
      useAlert(
        t('BULK_ACTION.EMAIL_DELETE.PARTIAL', {
          count: failures.value.length,
        })
      );
    } else {
      dialog.value?.close();
      useAlert(t('BULK_ACTION.EMAIL_DELETE.SUCCESS'));
    }
    data.results
      .filter(result => result.deleted)
      .forEach(result => {
        store.dispatch('bulkActions/removeSelectedConversationIds', result.id);
      });
  } catch (error) {
    useAlert(
      error?.response?.data?.error || t('BULK_ACTION.EMAIL_DELETE.ERROR')
    );
  } finally {
    loading.value = false;
  }
};
</script>

<template>
  <Button
    v-if="available"
    :label="t('BULK_ACTION.EMAIL_DELETE.BUTTON')"
    icon="i-lucide-trash-2"
    ruby
    xs
    ghost
    @click="open('trash')"
  />
  <Button
    v-if="available"
    :label="t('BULK_ACTION.EMAIL_DELETE.SPAM_BUTTON')"
    icon="i-lucide-shield-alert"
    ruby
    xs
    ghost
    @click="open('spam')"
  />
  <Dialog
    ref="dialog"
    type="alert"
    :title="
      t('BULK_ACTION.EMAIL_DELETE.TITLE', { count: conversationIds.length })
    "
    :description="
      mode === 'spam'
        ? t('BULK_ACTION.EMAIL_DELETE.SPAM_DESCRIPTION')
        : t('BULK_ACTION.EMAIL_DELETE.DESCRIPTION')
    "
    :confirm-button-label="t('BULK_ACTION.EMAIL_DELETE.CONFIRM')"
    :disable-confirm-button="!canConfirm"
    :is-loading="loading"
    @confirm="deleteEmails"
  >
    <div class="flex flex-col gap-3 text-sm text-n-slate-11">
      <label class="flex items-center gap-2">
        <input v-model="mode" type="radio" value="trash" />
        {{ t('BULK_ACTION.EMAIL_DELETE.TRASH') }}
      </label>
      <label class="flex items-center gap-2">
        <input v-model="mode" type="radio" value="spam" />
        {{ t('BULK_ACTION.EMAIL_DELETE.SPAM') }}
      </label>
      <label class="flex items-center gap-2">
        <input v-model="mode" type="radio" value="permanent" />
        {{ t('BULK_ACTION.EMAIL_DELETE.PERMANENT') }}
      </label>
      <label v-if="mode === 'permanent'" class="flex flex-col gap-1">
        {{ t('BULK_ACTION.EMAIL_DELETE.TYPE_CONFIRMATION') }}
        <input
          v-model="confirmation"
          type="text"
          autocomplete="off"
          class="rounded-md border border-n-weak bg-n-alpha-2 p-2"
        />
      </label>
      <p v-if="conversationIds.length > 25">
        {{ t('BULK_ACTION.EMAIL_DELETE.LIMIT') }}
      </p>
      <ul v-if="failures.length" class="list-disc ps-5">
        <li v-for="failure in failures" :key="failure.id">
          #{{ failure.id }}: {{ failure.error }}
        </li>
      </ul>
    </div>
  </Dialog>
</template>
