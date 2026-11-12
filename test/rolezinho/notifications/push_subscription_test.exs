defmodule Rolezinho.Notifications.PushSubscriptionTest do
  use ExUnit.Case, async: true

  alias Rolezinho.Notifications.PushSubscription

  describe "allowed_endpoint?/1" do
    test "accepts the browser push services over https" do
      for url <- [
            "https://fcm.googleapis.com/fcm/send/abc",
            "https://updates.push.services.mozilla.com/wpush/v2/abc",
            "https://web.push.apple.com/QGc2abc",
            "https://wns2-par02p.notify.windows.com/w/?token=abc"
          ] do
        assert PushSubscription.allowed_endpoint?(url), url
      end
    end

    test "rejects anything that would point our server elsewhere" do
      for url <- [
            "http://fcm.googleapis.com/fcm/send/abc",
            "https://fcm.googleapis.com:8443/fcm/send/abc",
            "https://user:pw@fcm.googleapis.com/x",
            "https://fcm.googleapis.com.evil.com/x",
            "https://evilfcm.googleapis.com/x",
            "https://169.254.169.254/latest/meta-data",
            "https://localhost/x",
            "javascript:alert(1)",
            "not a url",
            ""
          ] do
        refute PushSubscription.allowed_endpoint?(url), url
      end

      refute PushSubscription.allowed_endpoint?(nil)
    end
  end
end
