var TieBaXOpenAction = function() {};

TieBaXOpenAction.prototype = {
    run: function(arguments) {
        arguments.completionFunction({ "url": document.URL });
    },

    finalize: function(arguments) {
        var deepLink = arguments["deepLink"];
        if (typeof deepLink === "string" && deepLink.indexOf("tiebax://open?") === 0) {
            window.location.assign(deepLink);
            return;
        }

        var errorMessage = arguments["errorMessage"];
        if (typeof errorMessage === "string" && errorMessage.length > 0) {
            window.alert(errorMessage);
        }
    }
};

var ExtensionPreprocessingJS = new TieBaXOpenAction();
