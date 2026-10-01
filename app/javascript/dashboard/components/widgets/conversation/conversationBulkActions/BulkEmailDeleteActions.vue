<script setup>
import { computed, ref } from 'vue';
import { useStore } from 'vuex';
import { useI18n } from 'vue-i18n';
import { useMapGetter } from 'dashboard/composables/store';
import { useAdmin } from 'dashboard/composables/useAdmin';
import { useAlert } from 'dashboard/composables';
import BulkActionsAPI from 'dashboard/api/bulkActions';
import mutationTypes from 'dashboard/store/mutation-types';
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
const selectedIds = ref([]);
const requestId = ref('');
const loading = ref(false);
const failures = ref([]);
const available = computed(
  () =>
    isAdmin.value &&
    props.conversationIds.length > 0 &&
    props.inboxIds.length > 0 &&
    props.inboxIds.every(
      id => getInbox.value(id)?.channel_type === 'Channel::Email'
    )
);
const canConfirm = computed(
  () =>
    !loading.value &&
    selectedIds.value.length > 0 &&
    selectedIds.value.length <= 25
);
const open = requestedMode => {
  if (loading.value) return;
  mode.value = requestedMode;
  selectedIds.value = [...props.conversationIds];
  requestId.value = crypto.randomUUID();
  failures.value = [];
  dialog.value?.open();
};
const deleteEmails = async () => {
  if (!canConfirm.value) return;
  loading.value = true;
  try {
    const { data } = await BulkActionsAPI.deleteEmailConversations({
      ids: selectedIds.value,
      mode: mode.value,
      request_id: requestId.value,
    });
    const results = selectedIds.value.map(
      id =>
        data.results?.find(result => result.id === id) || {
          id,
          error: t('BULK_ACTION.EMAIL_DELETE.UNCONFIRMED'),
        }
    );
    failures.value = results.filter(
      result => result.error || (!result.deleted && !result.spam)
    );
    results
      .filter(result => result.deleted || result.spam)
      .forEach(result => {
        store.dispatch('bulkActions/removeSelectedConversationIds', result.id);
        if (result.deleted)
          store.commit(mutationTypes.DELETE_CONVERSATION, result.id);
      });
    store.dispatch('conversationStats/get');
    if (failures.value.length) {
      selectedIds.value = failures.value.map(result => result.id);
      useAlert(
        t('BULK_ACTION.EMAIL_DELETE.PARTIAL', { count: failures.value.length })
      );
    } else {
      dialog.value?.close();
      useAlert(
        t(
          mode.value === 'spam'
            ? 'BULK_ACTION.EMAIL_DELETE.SPAM_SUCCESS'
            : 'BULK_ACTION.EMAIL_DELETE.SUCCESS'
        )
      );
    }
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
    :disabled="loading"
    @click="open('trash')"
  />
  <Button
    v-if="available"
    :label="t('BULK_ACTION.EMAIL_DELETE.SPAM_BUTTON')"
    icon="i-lucide-shield-alert"
    ruby
    xs
    ghost
    :disabled="loading"
    @click="open('spam')"
  />
  <Dialog
    ref="dialog"
    type="alert"
    :title="
      t(
        mode === 'spam'
          ? 'BULK_ACTION.EMAIL_DELETE.SPAM_TITLE'
          : 'BULK_ACTION.EMAIL_DELETE.TITLE',
        { count: selectedIds.length }
      )
    "
    :description="
      t(
        mode === 'spam'
          ? 'BULK_ACTION.EMAIL_DELETE.SPAM_DESCRIPTION'
          : 'BULK_ACTION.EMAIL_DELETE.DESCRIPTION'
      )
    "
    :confirm-button-label="
      t(
        mode === 'spam'
          ? 'BULK_ACTION.EMAIL_DELETE.SPAM_CONFIRM'
          : 'BULK_ACTION.EMAIL_DELETE.CONFIRM'
      )
    "
    :disable-confirm-button="!canConfirm"
    :is-loading="loading"
    :show-cancel-button="!loading"
    @confirm="deleteEmails"
  >
    <div class="flex flex-col gap-3 text-sm text-n-slate-11">
      <p>
        {{
          t('BULK_ACTION.EMAIL_DELETE.SELECTION', {
            ids: selectedIds.map(id => `#${id}`).join(', '),
          })
        }}
      </p>
      <p v-if="selectedIds.length > 25">
        {{ t('BULK_ACTION.EMAIL_DELETE.LIMIT') }}
      </p>
      <ul v-if="failures.length" class="list-disc ps-5">
        <li v-for="failure in failures" :key="failure.id">
          #{{ failure.id }}:
          {{ failure.error || t('BULK_ACTION.EMAIL_DELETE.UNCONFIRMED') }}
        </li>
      </ul>
    </div>
  </Dialog>
</template>
