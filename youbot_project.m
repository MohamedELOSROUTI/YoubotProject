function youbot_project()
    clc, clearvars, close all

    run('../../matlab/startup_robot.m')
    
    
    %% Parameters
    use_getPosition = true;
    plot_data = true;
    
    nb_iter = 0;
    nb_iter_per_plot = 50;
    
    front_angle = 15; %�
    
    remap_distance = 1.5; %m
    remap = false;
    
    mapping_fig = figure('Name', 'Mapping', 'NumberTitle', 'Off', 'visible', 'Off');
    ylabel('Y');
    xlabel('X');
    
    
    %% Initiate the connection to the simulator. 
    disp('Program started');
    
    vrep = remApi('remoteApi');
    vrep.simxFinish(-1);
    id = vrep.simxStart('127.0.0.1', 19997, true, true, 2000, 5);
    
    if id < 0
        disp('Failed connecting to remote API server. Exiting.');
        vrep.delete();
        return;
    end
    fprintf('Connection %d to remote API server open.\n', id);
    
    % Make sure to close the connection whenever the script is interrupted.
    cleanupObj = onCleanup(@() cleanup_vrep(vrep, id));
    
    vrep.simxStartSimulation(id, vrep.simx_opmode_oneshot_wait);
    
    % Retrieve all handles, and stream arm and wheel joints, the robot's pose, the Hokuyo, and the arm tip pose.
    h = youbot_init(vrep, id);
    h = youbot_hokuyo_init(vrep, h);
    
    pause(.2);
    
    
    %% Youbot constants
    % The time step the simulator is using (your code should run close to it). 
    timestep = .05;

    % Minimum and maximum angles for all joints. Only useful to implement custom IK. 
    armJointRanges = [-2.9496064186096, 2.9496064186096;
                      -1.5707963705063, 1.308996796608;
                      -2.2863812446594, 2.2863812446594;
                      -1.7802357673645, 1.7802357673645;
                      -1.5707963705063, 1.5707963705063 ];

    % Definition of the starting pose of the arm (the angle to impose at each joint to be in the rest position).
    startingJoints = [0, 30.91 * pi / 180, 52.42 * pi / 180, 72.68 * pi / 180, 0];
    
    
    % Parameters for controlling the youBot's wheels: at each iteration, those values will be set for the wheels. 
    % They are adapted at each iteration by the code. 
    forwBackVel = 0; % Move straight ahead. 
    rightVel = 0; % Go sideways. 
    rotateRightVel = 0; % Rotate. 
    prevOrientation = 0; % Previous angle to goal (easy way to have a condition on the robot's angular speed). 
    prevPosition = 0; % Previous distance to goal (easy way to have a condition on the robot's speed).
    
    
    % Youbot's map
    map = OccupancyMap([201 201], 0.25);
    center = round( (size(map.Map) + 1) /2 );
    
    figure(mapping_fig);
    map.plot();
    set(mapping_fig, 'visible', 'on');
    
    dstar = youbotDstar(zeros(size(map.Map)), 'quiet');
    
    
    % Youbot initial position
    [res, originPos] = vrep.simxGetObjectPosition(id, h.ref, -1, vrep.simx_opmode_buffer);
    vrchk(vrep, res, true);
    prevPosition = originPos(1:2);
    [res, originEuler] = vrep.simxGetObjectOrientation(id, h.ref, -1, vrep.simx_opmode_buffer);
    vrchk(vrep, res, true);
    prevOrientation = originEuler(3);
    
    % Target position
    targets_q = Queue();
    targets_q.push([originPos(1) originPos(2)]);
%     targets_q.push([originPos(1) originPos(2)+10]);
%     targets_q.push([originPos(1)-2 originPos(2)+10]);
    cur_target = targets_q.front();
    
    dstar.plan(round(( targets_q.front()-originPos(1:2) )/map.MapRes) + center);
    
    
    % Voir comment l'enlever
    [X, Y] = meshgrid(-5:map.MapRes:5, -5.5:map.MapRes:2.5);
    
    
    % Finite State Machine first state
    fsm = 'map';
    
    %% Start
    disp('Enter loop')
    while true
        start_loop = tic;
        
        if vrep.simxGetConnectionId(id) == -1
            error('Lost connection to remote API.');
        end
        
        
        % Get the position and the orientation of the robot.
        % Mean=2.7E-4s  /  Min=1.8E-4s  /  Max=9.5ms
        [res, youbotPos] = vrep.simxGetObjectPosition(id, h.ref, -1, vrep.simx_opmode_buffer);
        vrchk(vrep, res, true);
        [res, youbotEuler] = vrep.simxGetObjectOrientation(id, h.ref, -1, vrep.simx_opmode_buffer);
        vrchk(vrep, res, true);
        
        % Youbot rotation matrix (to put local coordinates in global axes)
        rotationMatrix = ...
            [cos(youbotEuler(3)) -sin(youbotEuler(3)) 0;...
             sin(youbotEuler(3)) cos(youbotEuler(3))  0;...
             0                   0                    1];
         
        ii = round(youbotPos(1) - originPos(1)) + center(1);
        jj = round(youbotPos(2) - originPos(2)) + center(2);
        
        
        %% Finite State Machine
        if strcmp(fsm, 'map')
            % Get sensor infos
            % Mean=23ms  /  Min=16ms  /  Max=114ms
            [pts, contacts] = youbot_hokuyo(vrep, h, vrep.simx_opmode_buffer); % Mean=1ms
            in = inpolygon(X, Y,...
                [h.hokuyo1Pos(1), pts(1, :), h.hokuyo2Pos(1)],...
                [h.hokuyo1Pos(2), pts(2, :), h.hokuyo2Pos(2)]); % Assez lent, voir pour l'enlever ou acc�l�rer
            
            % Rotated points (to avoid using sine and cosine in code)
            r_pts = rotationMatrix*pts;
            
            
            % Retrieve location information
            % Mean=5.4E-4s  /  Min=3.2E-4s  /  Max=10.5ms
            x_pts = youbotPos(1) - originPos(1) + X(in)*cos(youbotEuler(3)) - Y(in)*sin(youbotEuler(3));
            x_contact = youbotPos(1) - originPos(1) + r_pts(1, contacts);

            y_pts = youbotPos(2) - originPos(2) + Y(in)*cos(youbotEuler(3)) + X(in)*sin(youbotEuler(3));
            y_contact = youbotPos(2) - originPos(2) + r_pts(2, contacts);

            map.add_points(-round(y_pts/map.MapRes) + center(1), round(x_pts/map.MapRes) + center(2), map.Free);
            map.add_points(-round(y_contact/map.MapRes) + center(1), round(x_contact/map.MapRes) + center(2), map.Wall);
            
            
            % Update dstar costmap if map has evolved
            % Conditions of remap
            %   - If a obstacle in front of the robot is too close
            %   - If the point queue is empty (target reached)
            % Mean=28ms  /  Min=3.3ms  /  Max=4s
            if remap
                remap = false;
                dstar.modify_cost([round(x_contact/map.MapRes) + center(2) ;-round(y_contact/map.MapRes) + center(1)], Inf);
                
                dstar.plan(round(( cur_target-originPos(1:2) )/map.MapRes) + center);
                dm = dstar.distancemap_get();
                % When the house is fully, the distancemap should show Inf
                % inside the house => map fully discovered => end mapping
                if dm(jj, ii) == Inf  % Check indexes order
                    fsm = 'end';
                end
            end
                
            
            % Check in front of the robot
            in_front = abs(pts(1,:)./pts(2,:)) < tan(front_angle*pi/180);
            d = sqrt(r_pts(1,contacts & in_front).^2 + r_pts(2,contacts & in_front).^2);
            if min(d) < remap_distance
                remap = true;
            end
        end
        
        
        %% Youbot drive system
        % Mean=5.8E-4s  /  Min=3.7E-4s  /  Max=23ms
        % Compute angle velocity
        rotateRightVel = 0 - youbotEuler(3);
        if (abs(angdiff(0, youbotEuler(3))) < .1 / 180 * pi) && ...
                    (abs(angdiff(prevOrientation, youbotEuler(3))) < .01 / 180 * pi)
            rotateRightVel = 0;
        end
        % Compute forward velocity
        robotVel = cur_target - youbotPos(1:2);
        robotVel( abs(robotVel) < .001 & abs(youbotPos(1:2) - prevPosition) < .001 ) = 0;
        % Previous position and orientation
        prevPosition = youbotPos(1:2);
        prevOrientation = youbotEuler(3);
        % Set youbot velocities
        if remap
            % Slow down the robot if we need to remap
            robotVel = robotVel./4;
            rotateRightVel = rotateRightVel/4;
        end
        h = youbot_drive(vrep, h, robotVel(2), robotVel(1), 0);
        
        
        %% Handle targets queue
        % Check if target reached, if yes then get the next target from
        % queue (check if queue is empty, if yes set current position as
        % target so the robot wont move until further indications)
        if all(abs(youbotPos(1:2) - cur_target) <= 0.01) && ~any(size(targets_q.front()) == 0)
            cur_target = targets_q.next();
            if any(size(cur_target) == 0)
                cur_target = youbotPos(1:2);
                
                remap = true; % Maybe add condition on fsm='map'
            end
        end
        
        
        %% Plotting
        % Show map (if needed: see 'plot_data' )
        % Mean=19.4ms  /  Min=10.5ms  /  Max=440ms
        if plot_data && mod(nb_iter, nb_iter_per_plot) == 0
            figure(mapping_fig);
            
            map.plot();
            title(sprintf('Mapping after %1$d iterations', nb_iter));
            hold on;
            
            scatter(youbotPos(1) - originPos(1) + center(1)*map.MapRes, -(youbotPos(2) - originPos(2)) + center(2)*map.MapRes, '*', 'r')
            hold off;
        end
        
        % Count number of times while is executed to save execution time on
        % mapping
        nb_iter = nb_iter + 1;
        
        
        %% Calculation time control
        ellapsed = toc(start_loop);
        remaining = timestep - ellapsed;
        if remaining > 0
            pause(min(remaining, .01));
        end
    end
end