class TaskDeliveryMessage < ApplicationRecord
  belongs_to :task_delivery
  belongs_to :message, primary_key: :message_id
end
